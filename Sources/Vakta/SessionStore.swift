//
//  SessionStore.swift
//  Vakta
//
//  Owns the session list + selection (ObservableObject, drives the SwiftUI
//  sidebar chrome) and the single shared `TerminalController` (one
//  `ghostty_app_t` for the whole process -- see docs/architecture.md's
//  "Single shared terminal controller" invariant).
//
//  This type also owns `hostContainer`, the AppKit view every session's
//  surface lives in for the app's lifetime (docs/architecture.md's
//  "Permanent AppKit terminal host" invariant). See `TerminalContainer.swift`
//  for why creation/removal/selection are all imperative calls into that
//  view rather than anything SwiftUI-driven.

import AppKit
import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme

/// One unseen-attention herdr *workspace*, not a whole Vakta session:
/// discovered live that a single herdr session/socket can host several
/// workspaces (e.g. "guildhall"/"vakta"/"data-platform" sharing one
/// session) -- `AgentStatus`'s per-session `.busiest` aggregate can't tell
/// "this workspace needs you" apart from "a different workspace in the same
/// session is merely working," so unread tracking needs this finer grain.
struct UnreadPane: Identifiable, Equatable {
    var sessionID: Session.ID
    var paneID: String
    var workspaceID: String?
    var label: String
    /// The status that caused this to be marked unread -- shown in the bell
    /// popover so an entry says *why* (e.g. "Needs attention" vs. "Done"),
    /// not just which workspace.
    var status: AgentStatus
    var id: String { paneID }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var selectedID: Session.ID?

    /// Profiles a new session can be created from. The first is the default
    /// (what the sidebar's `+` and the menu's plain "New Session" use).
    /// Persisted to disk on every change (see `ProfilePersistence`).
    @Published var profiles: [Profile] {
        didSet { ProfilePersistence.save(profiles, root: root) }
    }

    /// The profile a plain "New Session" uses. `nil` means "the first profile"
    /// (the historical behavior). Editable in the Sessions preferences pane;
    /// persisted on change.
    @Published var defaultProfileID: Profile.ID? {
        didSet { SessionSettingsPersistence.saveDefaultProfileID(defaultProfileID, root: root) }
    }

    /// Existing multiplexer sessions discovered on the server, keyed by the
    /// profile that can attach them. Populated on demand by `refreshDiscovery`
    /// and offered in the "New Session" menu -- never auto-added to the sidebar.
    /// No entry at all for a profile that isn't a known multiplexer (nothing
    /// to show); `.unsupported` for one that is, but whose target can't be
    /// reliably queried (e.g. herdr `--remote`) -- kept distinct from
    /// `.sessions([])` so "can't tell you" never looks like "confirmed empty."
    @Published private(set) var discovered: [Profile.ID: DiscoveryResult] = [:]

    /// Saved workspace records whose profile no longer exists, set once at
    /// startup by `WorkspaceStartupPlanner` and never auto-launched under a
    /// substituted profile. Not surfaced in any UI yet (no recovery flow
    /// exists) -- kept here so one exists to build against, and so this data
    /// isn't simply discarded.
    @Published private(set) var unresolvedWorkspaceRecords: [SessionRecord] = []

    /// The session id `requestClose` most recently asked to close that
    /// Ghostty rejected (or had no surface to ask) -- `nil` once a close
    /// request succeeds. Not surfaced in any UI yet; see `requestClose`.
    @Published private(set) var lastRejectedClose: Session.ID?

    /// Herdr *workspaces* (not whole Vakta sessions -- see `UnreadPane`'s
    /// doc comment) with an attention transition the user hasn't seen yet
    /// (see `UnreadAttentionPolicy`). Backs the sidebar bell popover and
    /// `goToNextUnreadSession`. An entry is removed when its exact pane is
    /// focused via `focusWorkspace`, when the encompassing session is
    /// removed, or -- opportunistically, in `pollAgentStatus` -- the moment
    /// a poll observes it as both selected and herdr-focused with the app
    /// active, i.e. the user is now actually looking at it. Deliberately
    /// independent of the notifyOnAttention/bounceDock preference toggles --
    /// see `UnreadAttentionPolicy`'s doc comment.
    @Published private(set) var unreadPanes: [UnreadPane] = []
    /// Previous status per herdr pane id, so `pollAgentStatus` can detect a
    /// real transition per *pane* -- `agentStatus` only holds one
    /// already-aggregated `.busiest` value per Vakta session, which can't
    /// tell "workspace A just became blocked" apart from "workspace B (also
    /// in this session) is still merely working."
    private var previousPaneStatus: [String: AgentStatus] = [:]
    /// The pane id herdr last reported as focused for a given session, if
    /// any -- lets `clearUnreadForSelectedSessionIfAppActive` clear
    /// responsively on app activation without waiting for the next poll.
    private var lastKnownFocusedPaneID: [Session.ID: String] = [:]

    /// Per-session agent status (herdr sessions only), polled from
    /// `herdr agent list` and shown as a colored dot in the sidebar. The Dock
    /// badge (count of sessions needing attention) is derived here so both the
    /// poll and `removeSession` keep it correct with no extra call sites.
    @Published private(set) var agentStatus: [Session.ID: AgentStatus] = [:] {
        didSet { updateDockBadge() }
    }

    /// A session's workspaces (local machine only -- see `Workspace.swift`),
    /// fetched once when its sidebar row is first expanded (gated by
    /// `HerdrPreferencesStore.showWorkspaces`), not continuously polled.
    /// `nil` until fetched at least once; `[]` means "fetched, none" -- both
    /// display the same empty disclosure.
    @Published private(set) var workspaces: [Session.ID: [Workspace]] = [:]

    /// A workspace's own agent status, keyed by workspace id -- lets
    /// `WorkspaceRow` show a workspace's actual status (e.g. a
    /// checkmark for `.done`) instead of only the encompassing session's
    /// aggregate `.busiest` value, which can't distinguish one workspace
    /// from another sharing the same session (see `UnreadPane`'s doc
    /// comment for the same discovery). Populated every poll in
    /// `applyPaneUpdates`; not published until the first poll after launch.
    @Published private(set) var paneStatusByWorkspaceID: [String: AgentStatus] = [:]

    /// Fallback repeating poll for `agentStatus` -- stays active unchanged
    /// even once `herdrEventClients` exist (defense in depth: a bug in the
    /// socket path never regresses status updates below this cadence). Each
    /// event client's `onTrigger` also calls `pollAgentStatus()` early,
    /// debounced via `pendingEventTriggeredPoll`, for near-instant updates.
    private var statusTimer: Timer?
    /// At most one agent-status poll, and separately at most one discovery
    /// refresh, in flight at a time -- see `SingleFlightGate`.
    private let agentStatusPollGate = SingleFlightGate()
    private let discoveryGate = SingleFlightGate()
    /// One socket event-subscription client per live herdr session (see
    /// `HerdrEventStreamClient`) -- created in `createSession`, stopped and
    /// removed in `removeSession`. Absent for non-herdr sessions and herdr
    /// sessions whose target isn't reliably queryable (matches
    /// `pollAgentStatus`'s own `.unsupported` handling).
    private var herdrEventClients: [Session.ID: HerdrEventStreamClient] = [:]
    /// The pane-id set each `herdrEventClients` entry is currently
    /// subscribed with, so `pollAgentStatus` can detect membership changes
    /// via `HerdrPaneRegistry` and call `updatePaneIDs` only when it did.
    private var herdrSubscribedPaneIDs: [Session.ID: Set<String>] = [:]
    /// Debounces a burst of `HerdrEventStreamClient.onTrigger` calls (e.g.
    /// several panes changing status at once) into one `pollAgentStatus()`
    /// call, matching the 150ms debounce already used for terminal
    /// settings changes elsewhere in this type.
    private var pendingEventTriggeredPoll: DispatchWorkItem?
    /// Set once, in `deinit`; polled by in-flight `ProcessRunner` calls
    /// (`isCancelled`) from their own background thread, so a helper
    /// process started just before shutdown is terminated instead of
    /// running to its own timeout regardless. `nonisolated(unsafe)` rather
    /// than actor-hopping on every poll iteration of a tight cancellation
    /// check: a `Bool` write/read can't tear on this platform, this is the
    /// only writer, and it only ever transitions `false` -> `true` -- a
    /// reader that still observes `false` for one more 20ms poll iteration
    /// after the true write simply cancels one iteration later, which is
    /// harmless (see `BoundedProcessRunner`'s poll loop).
    private nonisolated(unsafe) var isShuttingDown = false

    /// Surfaces agent-status transitions as notifications / a Dock bounce.
    /// `AppDelegate` finishes wiring it (settings, activation callback, and
    /// authorization) once the app has launched.
    let notifier = AttentionNotifier()

    /// One `ghostty_app_t` for the whole process. Every `Session` this store
    /// creates is handed this same controller.
    let controller: TerminalController

    /// User-chosen terminal font + theme. Observed here and pushed to the
    /// controller live.
    let terminalSettings: TerminalSettingsStore
    private var terminalSettingsObserver: AnyCancellable?

    /// Which statuses populate `unreadPanes` -- see `UnreadTrackingSettings`.
    let unreadTrackingSettings: UnreadTrackingSettingsStore

    /// The current terminal theme's colors as `NSColor`s, so the sidebar can
    /// match the terminal (background as one continuous surface; selection and
    /// accent so its highlight matches herdr's palette). `@Published` because
    /// they follow the theme when it changes at runtime -- SwiftUI parts update
    /// for free; `AppDelegate` re-applies the AppKit parts (see its sink).
    @Published private(set) var terminalBackgroundColor: NSColor = .windowBackgroundColor
    @Published private(set) var terminalSelectionColor: NSColor = .selectedContentBackgroundColor
    @Published private(set) var terminalAccentColor: NSColor = .controlAccentColor

    /// The persistent AppKit container all session surfaces live in.
    /// Created once, added to the window's view hierarchy exactly once, and
    /// never recreated for the life of the app.
    let hostContainer = TerminalHostContainerView()

    /// `VAKTA_TERMINAL_COMMAND`, applied to every session's command at spawn
    /// time (smoke-testing where herdr isn't installed). Applied in
    /// `createSession`, never written into `profiles`, so it can't leak into
    /// the persisted file.
    private let commandOverride: String?

    /// The user's login-shell PATH. Injected into every spawned session so a
    /// bare command (e.g. `herdr` in `~/.local/bin`) resolves even when
    /// Vakta was launched from a `.app` with a minimal PATH. Starts as the
    /// static fallback (see `ShellEnvironment.fallbackPATH`) and is updated
    /// once the real value resolves in the background -- see `init` and
    /// `finishLaunch`. Sessions created before it lands (the restored
    /// workspace, or one the user manually creates in that window) use the
    /// fallback; there is no retroactive fixup for already-spawned children.
    private var resolvedPATH: String

    private let root: URL

    /// True only while `init` is recreating sessions from a saved workspace.
    /// Suppresses `saveWorkspace()` so restoring N records writes the file
    /// once (via the explicit flush in `init`), or not at all when the
    /// startup plan says not to persist -- not N times, progressively, as
    /// each session is created.
    private var isRestoringWorkspace = false

    /// Computed in `init` (see there for why it can't wait for `finishLaunch`)
    /// and consumed exactly once by `finishLaunch`.
    private var pendingWorkspaceDecision: WorkspaceStartupDecision?

    /// The profile used when `createSession` is called with no explicit one:
    /// the user's chosen default, else the first profile (else the built-in
    /// herdr profile if the list is somehow empty).
    var defaultProfile: Profile {
        DefaultProfileSelector.select(from: profiles, defaultProfileID: defaultProfileID)
    }

    /// `pathResolver` (kicked off by the caller as early in launch as
    /// possible -- see `ResolvedPATH`) resolves the login-shell PATH on a
    /// background thread. `init` does NOT wait on it: waiting here, even on
    /// a background thread, would still keep the caller (the main actor,
    /// during app launch) blocked until the result lands -- exactly what
    /// this issue exists to fix. Instead `init` uses the static fallback
    /// PATH immediately and finishes launching (workspace restore,
    /// discovery, status polling) once the real value is ready, on a
    /// background thread the whole time; only the final `self.resolvedPATH
    /// = path` + `finishLaunch()` hop back to the main actor.
    init(terminalSettings: TerminalSettingsStore, unreadTrackingSettings: UnreadTrackingSettingsStore, root: URL, pathResolver: ResolvedPATH) {
        self.terminalSettings = terminalSettings
        self.unreadTrackingSettings = unreadTrackingSettings
        self.root = root
        commandOverride = ProcessInfo.processInfo.environment["VAKTA_TERMINAL_COMMAND"]
        resolvedPATH = ShellEnvironment.fallbackPATH()

        // Load saved profiles; first launch seeds the built-ins and writes
        // them. A corrupt/unreadable file falls back to the built-ins for
        // this run only -- it is deliberately NOT overwritten (see
        // `PersistedFileStore`). Assigning `profiles` in init does not fire
        // its `didSet`, so the first-run seed is saved explicitly.
        let profilesOutcome = ProfilePersistence.load(root: root)
        let seeded: [Profile]
        switch profilesOutcome {
        case .missing: seeded = [.herdr, .tmux, .shell]
        case .loaded(let saved): seeded = saved
        case .corrupt, .unreadable: seeded = [.herdr, .tmux, .shell]
        }
        profiles = seeded
        if case .missing = profilesOutcome {
            ProfilePersistence.save(seeded, root: root)
        }

        // The chosen default profile for new sessions (nil -> first profile
        // is always a safe fallback, whether unset, missing, corrupt, or
        // unreadable). Assigning in init does not fire `didSet`, so nothing
        // is re-saved here.
        switch SessionSettingsPersistence.load(root: root) {
        case .missing, .corrupt, .unreadable:
            defaultProfileID = nil
        case .loaded(let payload):
            defaultProfileID = payload.defaultProfileID
        }

        // Resolve the user's chosen theme through the one shared resolution
        // path (see `TerminalThemeResolver`) also used by live updates in
        // `applyTerminalSettings`, so an unknown/stale theme name falls back
        // the same way at launch as it does mid-session, and the terminal
        // and derived sidebar colors below always agree (both come from the
        // same `definition`, never a `TerminalTheme.default` paired with
        // separately-computed neutral colors).
        let definition = TerminalThemeResolver.resolve(themeName: terminalSettings.themeName)
        let theme = definition.toTerminalTheme()

        let snapshot = terminalSettings.snapshot
        controller = TerminalController(theme: theme) { builder in
            Self.configureBuilder(&builder, with: snapshot)
        }

        // Push terminal font/theme changes to the shared controller live. The
        // controller's setters guard on equality, so the initial emission from
        // each `@Published` is a harmless no-op. Debounced so a stepper drag
        // reconfigures once, not per tick.
        terminalSettingsObserver = Publishers.MergeMany(
            terminalSettings.$fontFamily.map { _ in () }.eraseToAnyPublisher(),
            terminalSettings.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            terminalSettings.$themeName.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
        .sink { [weak self] in self?.applyTerminalSettings() }

        // All stored properties are now initialized, so the derived sidebar
        // colors can be set (synchronously, before the window reads them).
        applyThemeColors(from: definition)

        // Decided here, before any window/UI exists and therefore before
        // the user can possibly act, NOT inside the deferred `finishLaunch`
        // below: if this read were deferred too, a session the user
        // manually creates during the PATH-resolution gap would call
        // `saveWorkspace()` and overwrite `workspace.json` with just that
        // one session BEFORE `finishLaunch` ever read it -- silently
        // discarding the entire previous workspace. Reading now means
        // `finishLaunch` restores from what was actually on disk at launch,
        // regardless of what happens in between.
        pendingWorkspaceDecision = WorkspaceStartupPlanner.plan(
            for: WorkspacePersistence.load(root: root),
            profiles: profiles
        )

        // The rest of launch (workspace restore, discovery, status polling)
        // waits for the real PATH -- see the `init` doc comment. The wait
        // itself runs entirely on a background thread; only applying the
        // result hops back to the main actor.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let path = pathResolver.value(waitingUpTo: 4)
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolvedPATH = path
                self.finishLaunch()
            }
        }
    }

    /// Restores the previous workspace (from `pendingWorkspaceDecision`,
    /// computed in `init`), then starts discovery/status polling. Split out
    /// of `init` so it can run once the real PATH is resolved (or its
    /// bounded wait falls back) instead of blocking launch on it -- see
    /// `init`. A session the user manually creates in the window before
    /// this runs (the sidebar's `+`, e.g.) uses whatever `resolvedPATH` is
    /// at that moment -- the fallback, most likely, since this typically
    /// finishes well under a second -- with no retroactive fixup; it
    /// coexists with whatever `finishLaunch` then restores rather than
    /// being replaced by it, since the restore decision was already fixed
    /// before that manual session could exist.
    private func finishLaunch() {
        // Restore the previous workspace: recreate a session per resolved
        // record, each re-attaching (herdr/tmux) to its still-running server
        // session, from the decision `init` already computed -- reading
        // `workspace.json` again here, instead, would race a session the
        // user manually created during the PATH-resolution gap: that
        // session's own `saveWorkspace()` would have already overwritten
        // the file with just itself, and this would "restore" from that
        // instead of what was actually saved at launch. `isRestoringWorkspace`
        // suppresses `saveWorkspace()` for the duration (each `createSession`
        // below would otherwise call it once per record, progressively
        // rewriting the file with a partial list) -- the plan decided once,
        // in `init`, whether the end result needs persisting at all. A
        // corrupt/unreadable file is deliberately NOT overwritten with the
        // single-default-session fallback (see `WorkspaceStartupPlanner`).
        guard let decision = pendingWorkspaceDecision else { return }
        pendingWorkspaceDecision = nil
        switch decision {
        case .restore(let toCreate, let unresolved, let selectedSessionName, let shouldPersist):
            unresolvedWorkspaceRecords = unresolved
            isRestoringWorkspace = true
            if toCreate.isEmpty {
                // Fresh launch, or every saved record's profile is gone
                // (`unresolved`, kept above rather than launched under an
                // unrelated substituted profile): attach the persistent
                // `default` session rather than spawning a brand-new one
                // (verified: `herdr --session default` attaches, it doesn't
                // create a duplicate).
                createSession(sessionName: "default")
            } else {
                for resolved in toCreate {
                    createSession(
                        profile: resolved.profile,
                        sessionName: resolved.record.sessionName,
                        customName: resolved.record.customName,
                        workingDirectory: resolved.record.workingDirectory
                    )
                }
                // `createSession` selects whatever it just created, so the
                // loop above leaves the LAST restored session selected.
                // Override with the actually-saved selection, if it's one of
                // the sessions just restored.
                if let selectedSessionName,
                   let match = sessions.first(where: { $0.sessionName == selectedSessionName }) {
                    select(match.id)
                }
            }
            isRestoringWorkspace = false
            if shouldPersist {
                saveWorkspace()
            }
        }

        refreshDiscovery()
        startStatusPolling()
    }

    // MARK: Terminal font + theme

    /// Fills a terminal config builder with the settled keybind-clear plus the
    /// user's font. ALWAYS emits `keybind = clear` (docs/architecture.md's
    /// "Keybindings routed through the matcher, not menu key equivalents"
    /// invariant) so a font-only change can't drop it -- `setTerminalConfiguration`
    /// replaces the whole config rather than merging. Empty font family / zero
    /// size are omitted so ghostty keeps its own default. The decision of which
    /// pairs to emit is `TerminalConfigurationDecisions.customPairs`, a pure
    /// function tested independently of this `Builder` type.
    private static func configureBuilder(
        _ builder: inout TerminalConfiguration.Builder,
        with settings: TerminalSettings
    ) {
        for pair in TerminalConfigurationDecisions.customPairs(for: settings) {
            builder.withCustom(pair.key, pair.value)
        }
    }

    /// Applies the current terminal settings to the shared controller live: the
    /// font config and the theme, plus the derived sidebar colors. The
    /// controller's setters no-op when nothing changed.
    private func applyTerminalSettings() {
        let snapshot = terminalSettings.snapshot
        let config = TerminalConfiguration(startingFrom: .default) { builder in
            Self.configureBuilder(&builder, with: snapshot)
        }
        controller.setTerminalConfiguration(config)

        // Same resolution path `init` uses -- see `TerminalThemeResolver`'s
        // doc comment for why this must always call `setTheme` (never skip
        // it for an unknown name) and always derive the sidebar colors from
        // the identical definition.
        let definition = TerminalThemeResolver.resolve(themeName: snapshot.themeName)
        controller.setTheme(definition.toTerminalTheme())
        applyThemeColors(from: definition)
    }

    /// Recomputes the sidebar-matching colors from a theme definition.
    private func applyThemeColors(from definition: GhosttyThemeDefinition) {
        terminalBackgroundColor = NSColor(hexString: definition.background)
            ?? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        terminalSelectionColor = NSColor(hexString: definition.selectionBackground)
            ?? NSColor(srgbRed: 0.27, green: 0.28, blue: 0.35, alpha: 1)
        terminalAccentColor = NSColor(hexString: definition.palette[4]) ?? .controlAccentColor
    }

    // MARK: Agent status polling

    private func startStatusPolling() {
        pollAgentStatus()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAgentStatus() }
        }
        statusTimer = timer
    }

    /// Queries `herdr agent list` per herdr session (off the main thread) and
    /// republishes `agentStatus`. Non-herdr sessions and failed queries keep
    /// their previous value rather than flicker. A herdr session whose
    /// target can't be reliably queried (e.g. `--remote`) is set to
    /// `.unavailable` directly, without a query -- leaving it at the
    /// default `.none` would look identical to "queried this server, no
    /// agents," which is exactly the wrong-server display this issue exists
    /// to prevent.
    ///
    /// `agentStatusPollGate` drops this tick entirely (rather than queueing
    /// it) if the previous poll hasn't finished -- see `SingleFlightGate`.
    /// `AgentStatusApplyPlanner` then drops any result for a session that
    /// was removed while the query was in flight, so a stale completion
    /// can't resurrect its status/Dock count/notification.
    private func pollAgentStatus() {
        guard agentStatusPollGate.beginIfIdle() else { return }

        var pollableSessions: [(id: Session.ID, name: String, target: MultiplexerTarget)] = []
        for session in sessions {
            switch LaunchTargetResolver.agentStatusPollOutcome(for: session.profile, sessionName: session.sessionName) {
            case .poll(let target):
                pollableSessions.append((session.id, session.sessionName, target))
            case .unavailable:
                agentStatus[session.id] = .unavailable
            case .skip:
                continue
            }
        }
        guard !pollableSessions.isEmpty else {
            agentStatusPollGate.end()
            return
        }
        let path = resolvedPATH

        DispatchQueue.global(qos: .utility).async {
            var updates: [AgentStatusUpdate] = []
            var panesBySession: [Session.ID: [HerdrAgentStatus.PaneAgentStatus]] = [:]
            for session in pollableSessions {
                if let result = HerdrAgentStatus.query(
                    sessionName: session.name,
                    target: session.target,
                    path: path,
                    isCancelled: { [weak self] in self?.isShuttingDown ?? true }
                ) {
                    updates.append(AgentStatusUpdate(sessionID: session.id, status: result.status))
                    panesBySession[session.id] = result.panes
                }
            }
            DispatchQueue.main.async {
                defer { self.agentStatusPollGate.end() }
                let liveIDs = Set(self.sessions.map(\.id))
                let accepted = AgentStatusApplyPlanner.accepted(
                    updates,
                    liveSessionIDs: liveIDs,
                    previous: self.agentStatus
                )
                for entry in accepted {
                    if entry.previous != entry.status, let session = self.sessions.first(where: { $0.id == entry.sessionID }) {
                        self.notifier.handleTransition(
                            sessionID: entry.sessionID,
                            title: session.displayTitle,
                            from: entry.previous,
                            to: entry.status,
                            isSelected: self.selectedID == entry.sessionID,
                            appActive: NSApp.isActive
                        )
                    }
                    self.agentStatus[entry.sessionID] = entry.status
                }
                self.applyPaneUpdates(panesBySession)
            }
        }
    }

    /// Per-pane half of a poll's result: detects real per-pane transitions
    /// (`agentStatus`'s per-session `.busiest` can't -- see `UnreadPane`'s
    /// doc comment), marks/clears `unreadPanes` via the same
    /// `UnreadAttentionPolicy` the whole-session path uses, and feeds
    /// `HerdrPaneRegistry` for the event-subscription pane set.
    private func applyPaneUpdates(_ panesBySession: [Session.ID: [HerdrAgentStatus.PaneAgentStatus]]) {
        let appActive = NSApp.isActive
        for (sessionID, panes) in panesBySession {
            guard self.sessions.contains(where: { $0.id == sessionID }) else { continue }
            let isSessionSelected = self.selectedID == sessionID
            if let focused = panes.first(where: \.focused) {
                self.lastKnownFocusedPaneID[sessionID] = focused.paneID
            }

            for pane in panes {
                let previous = self.previousPaneStatus[pane.paneID]
                self.previousPaneStatus[pane.paneID] = pane.status
                if let workspaceID = pane.workspaceID {
                    self.paneStatusByWorkspaceID[workspaceID] = pane.status
                }

                // "Actually looking at it right now" -- selected in Vakta,
                // this exact workspace has herdr's own focus (not some
                // other workspace sharing the same session), and the app is
                // frontmost. Cleared unconditionally on this, independent of
                // whether a transition just happened: covers the user
                // coming back to exactly this pane without an explicit
                // focus click.
                if isSessionSelected, pane.focused, appActive {
                    self.unreadPanes.removeAll { $0.paneID == pane.paneID }
                }

                guard previous != pane.status else { continue }
                // `isSelected` composes Vakta's own session selection with
                // herdr's per-pane `focused` -- `shouldMarkUnread` computes
                // `!(isSelected && appActive)`, so this yields exactly
                // "not really being looked at right now" without
                // duplicating that check here.
                if UnreadAttentionPolicy.shouldMarkUnread(
                    from: previous,
                    to: pane.status,
                    isSelected: isSessionSelected && pane.focused,
                    appActive: appActive,
                    trackedStatuses: self.unreadTrackingSettings.trackedStatuses
                ) {
                    // Update in place (not just skip) if already unread --
                    // e.g. marked for .attention, then transitions further
                    // to .done while still unseen: the bell should reflect
                    // the current reason, not freeze at the first one.
                    if let index = self.unreadPanes.firstIndex(where: { $0.paneID == pane.paneID }) {
                        self.unreadPanes[index].status = pane.status
                    } else {
                        self.unreadPanes.append(UnreadPane(
                            sessionID: sessionID,
                            paneID: pane.paneID,
                            workspaceID: pane.workspaceID,
                            label: pane.label,
                            status: pane.status
                        ))
                    }
                }
            }

            let paneIDs = Set(panes.map(\.paneID))
            let current = self.herdrSubscribedPaneIDs[sessionID] ?? []
            guard case .changed(let updated) = HerdrPaneRegistry.update(current: current, latest: paneIDs) else { continue }
            self.herdrSubscribedPaneIDs[sessionID] = updated
            self.herdrEventClients[sessionID]?.updatePaneIDs(updated)
        }
    }

    /// The Dock badge shows how many sessions are waiting on the user (agent
    /// status `.attention`); cleared when none are.
    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = DockBadgePlanner.label(for: Array(agentStatus.values))
    }

    /// Re-queries each multiplexer for its existing sessions (off the main
    /// thread) and republishes `discovered`. Cheap; call on launch and when the
    /// app becomes active so the "New Session" menu is reasonably fresh.
    /// `discoveryGate` drops this call entirely (rather than queueing it) if
    /// a previous refresh hasn't finished -- see `SingleFlightGate`.
    /// `DiscoveryApplyPlanner` then drops any result for a profile that was
    /// deleted, or changed enough to resolve to a different target, while
    /// the query was in flight -- a stale query result must not be applied
    /// as if it described the profile's current target.
    func refreshDiscovery() {
        guard discoveryGate.beginIfIdle() else { return }

        let candidates = profiles
        let path = resolvedPATH
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [DiscoveryQueryResult] = []
            for profile in candidates {
                let target = LaunchTargetResolver.resolve(profile)
                switch target {
                case .multiplexer(let multiplexerTarget):
                    let names = SessionDiscovery.names(
                        for: multiplexerTarget,
                        path: path,
                        isCancelled: { [weak self] in self?.isShuttingDown ?? true }
                    )
                    results.append(DiscoveryQueryResult(profileID: profile.id, queriedTarget: target, result: .sessions(names)))
                case .unsupported:
                    // Only a known-multiplexer profile whose target can't be
                    // reliably queried gets `.unsupported` -- a profile that
                    // isn't a multiplexer at all (e.g. a plain shell) gets no
                    // entry, since there was never anything to discover.
                    if LaunchTargetResolver.isKnownMultiplexerCommand(profile) {
                        results.append(DiscoveryQueryResult(profileID: profile.id, queriedTarget: target, result: .unsupported))
                    }
                }
            }
            DispatchQueue.main.async {
                defer { self.discoveryGate.end() }
                self.discovered = DiscoveryApplyPlanner.accepted(results, currentProfiles: self.profiles)
            }
        }
    }

    /// Opens an existing multiplexer session by name. If Vakta already has it
    /// open, just selects that row instead of attaching a second view --
    /// matched on target (backend + executable + environment/socket), not
    /// name alone, so a same-named session on a different server/backend is
    /// never mistaken for this one.
    func attachExisting(profile: Profile, name: String) {
        let target = LaunchTargetResolver.resolve(profile)
        if let existing = sessions.first(where: {
            $0.sessionName == name && LaunchTargetResolver.resolve($0.profile) == target
        }) {
            select(existing.id)
        } else {
            createSession(profile: profile, sessionName: name)
        }
    }

    @discardableResult
    func createSession(
        profile: Profile? = nil,
        sessionName: String? = nil,
        customName: String? = nil,
        workingDirectory: String? = nil
    ) -> Session {
        var profile = profile ?? defaultProfile
        if let workingDirectory {
            profile.workingDirectory = workingDirectory
        }
        if let commandOverride, !commandOverride.isEmpty {
            // Smoke-test override: bypass the multiplexer entirely (no args,
            // no scrub prefix).
            profile.command = commandOverride
            profile.arguments = ""
            profile.scrubbedEnvironmentKeys = []
        }

        // Give the child the user's real PATH so a bare command resolves under
        // a `.app`'s minimal PATH. A profile that sets its own PATH wins.
        if profile.environment["PATH"] == nil {
            profile.environment["PATH"] = resolvedPATH
        }

        // The HERDR_*/TMUX scrub is baked into the command as an `env -u …`
        // prefix (see `Profile.resolvedCommand`), applied to the child only --
        // Vakta never mutates its own `environ` (that crashes libghostty).

        let session = Session(
            controller: controller,
            profile: profile,
            sessionName: sessionName ?? Session.makeSessionName(),
            customName: customName
        )

        // `terminalDidClose` (-> `onClose`) is the wrapper's surfacing of
        // libghostty's `close_surface_cb` runtime callback -- fired when the
        // pty's foreground command exits (or the surface is asked to close).
        // `processAlive` is a hint, not a verified exit code: libghostty
        // reports what it observed on the pty side, which can race the
        // child's actual termination. It is dispatched here one runloop
        // turn later because `terminalDidClose` runs synchronously from
        // inside the surface's own teardown machinery; freeing the surface
        // (which removing its view does, via deinit) from that same call
        // stack is unsafe.
        session.viewState.onClose = { [weak self, weak session] processAlive in
            guard let self, let session else { return }
            DispatchQueue.main.async {
                self.removeSession(session.id, processAlive: processAlive)
            }
        }

        sessions.append(session)
        hostContainer.addSession(session)
        startHerdrEventClientIfApplicable(for: session)
        select(session.id)
        saveWorkspace()
        return session
    }

    /// Starts a `HerdrEventStreamClient` for `session` if it's a herdr
    /// session on a reliably-queryable target (matching `pollAgentStatus`'s
    /// own `.unsupported` handling). Starts with no known pane ids -- the
    /// next `pollAgentStatus` run (the immediate one from
    /// `startStatusPolling`, or the first timer tick) discovers them and
    /// calls `updatePaneIDs`.
    private func startHerdrEventClientIfApplicable(for session: Session) {
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(session.profile),
              let socketPath = target.eventStreamSocketPath(sessionName: session.sessionName)
        else { return }

        let client = HerdrEventStreamClient(
            socketPath: socketPath,
            initialPaneIDs: []
        )
        client.onTrigger = { [weak self] in
            DispatchQueue.main.async { self?.scheduleEventTriggeredPoll() }
        }
        herdrEventClients[session.id] = client
        herdrSubscribedPaneIDs[session.id] = []
        client.start()
    }

    /// Debounces a burst of `HerdrEventStreamClient.onTrigger` calls into
    /// one `pollAgentStatus()` call -- see `pendingEventTriggeredPoll`'s
    /// doc comment.
    private func scheduleEventTriggeredPoll() {
        pendingEventTriggeredPoll?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollAgentStatus() }
        pendingEventTriggeredPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    /// Renames a session and persists it. Routed through the store (rather than
    /// set on `Session` directly) so the workspace file stays in sync.
    func renameSession(_ id: Session.ID, to name: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        session.customName = trimmed.isEmpty ? nil : trimmed
        saveWorkspace()
    }

    /// Writes the current open sessions to disk (profile + multiplexer name +
    /// rename), so the next launch reopens and re-attaches to them.
    private func saveWorkspace() {
        guard !isRestoringWorkspace else { return }
        let records = sessions.map { session in
            SessionRecordBuilder.record(
                profileID: session.profile.id,
                sessionName: session.sessionName,
                customName: session.customName,
                workingDirectory: session.profile.workingDirectory,
                profiles: profiles
            )
        }
        // Records whose profile was missing at the last restore aren't in
        // `sessions` (they were never launched -- see `WorkspaceStartupPlanner`)
        // but must still round-trip through every subsequent save, or the
        // first rename/close/create after launch would silently drop them
        // for good instead of preserving them for a future recovery choice.
        let selectedSessionName = sessions.first { $0.id == selectedID }?.sessionName
        WorkspacePersistence.save(
            WorkspacePayload(records: records + unresolvedWorkspaceRecords, selectedSessionName: selectedSessionName),
            root: root
        )
    }

    /// Asks the still-running session's surface to close (e.g. a sidebar
    /// "Close Session" action). This does not itself remove the row --
    /// `onClose` above does that once libghostty confirms the surface
    /// actually closed. `performBindingAction` reports whether Ghostty
    /// accepted the request; a rejection (or no surface to ask -- see its
    /// own doc comment) previously discarded that outcome entirely. It's
    /// now observable via `lastRejectedClose`, an idempotent outcome:
    /// calling this again on a session that keeps rejecting just re-records
    /// the same id; a later accepted call on the same or another session
    /// clears it.
    func requestClose(_ id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Verified against the pinned libghostty-spm checkout: `strings` on
        // GhosttyKit.xcframework's macos-arm64_x86_64/libghostty.a lists
        // "close_surface" as a real embedded binding-action name (alongside
        // "close_tab"/"close_window", ruling out a typo'd near-miss). The
        // table itself is compiled from upstream Ghostty's Zig source and
        // isn't otherwise present as text in this Swift wrapper, so this is
        // as far as static verification goes without building Ghostty from
        // source; `performBindingAction`'s own return value is the runtime
        // confirmation on top of that (surfaced via `lastRejectedClose`).
        let accepted = session.viewState.performBindingAction("close_surface")
        lastRejectedClose = accepted ? nil : id
    }

    /// Forwards a Ghostty binding-action name to the selected session's
    /// surface (e.g. font-size zoom from `KeybindingMatcher`). A no-op with
    /// no selected session. Verified against the pinned libghostty-spm
    /// checkout the same way as `requestClose`'s `"close_surface"`: `strings`
    /// on GhosttyKit.xcframework's macos-arm64_x86_64/libghostty.a lists
    /// "increase_font_size"/"decrease_font_size"/"reset_font_size" as real
    /// embedded binding-action names.
    @discardableResult
    func performBindingActionOnSelectedSession(_ action: String) -> Bool {
        guard let selectedID, let session = sessions.first(where: { $0.id == selectedID }) else { return false }
        return session.viewState.performBindingAction(action)
    }

    /// `processAlive` (from `terminalDidClose`) is a hint on the child's pty
    /// state, not a verified exit code (see the call site's doc comment) --
    /// deliberately not acted on here; the row is removed the same way
    /// whether the close was user-requested or the child simply exited.
    /// `SessionRemovalPlanner.shouldRemove` makes the resulting idempotency
    /// explicit: a second close callback for an already-removed session
    /// (the exact "repeated close callback" case) is a documented no-op,
    /// not a re-derived guard.
    private func removeSession(_ id: Session.ID, processAlive: Bool) {
        let sessionIDsBeforeRemoval = sessions.map(\.id)
        guard SessionRemovalPlanner.shouldRemove(id, from: sessionIDsBeforeRemoval) else { return }

        sessions.removeAll { $0.id == id }
        hostContainer.removeSession(id)
        agentStatus[id] = nil
        for workspace in workspaces[id] ?? [] {
            paneStatusByWorkspaceID[workspace.id] = nil
        }
        workspaces[id] = nil
        herdrEventClients[id]?.stop()
        herdrEventClients[id] = nil
        herdrSubscribedPaneIDs[id] = nil
        unreadPanes.removeAll { $0.sessionID == id }
        lastKnownFocusedPaneID[id] = nil

        let fallback = SessionSelectionPlanner.fallbackAfterRemoval(
            removedID: id,
            sessionIDsBeforeRemoval: sessionIDsBeforeRemoval,
            previousSelection: selectedID
        )
        if fallback != selectedID {
            selectedID = fallback
            if let fallback {
                hostContainer.select(fallback)
            }
        }
        saveWorkspace()
    }

    /// Selecting a session does NOT by itself clear any of its unread panes:
    /// discovered live that one herdr session can host several workspaces,
    /// so merely selecting the session doesn't mean the user has seen the
    /// specific (possibly different) workspace that's actually `.attention`.
    /// `applyPaneUpdates`'s opportunistic clear (this session selected, the
    /// pane herdr reports as focused, app active) is what actually clears
    /// an entry, the next time a poll observes that combination.
    func select(_ id: Session.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        hostContainer.select(id)
        saveWorkspace()
    }

    /// Jumps to the specific workspace behind `pane` (via `focusWorkspace`,
    /// or a plain `select` if its workspace id is somehow unknown) and
    /// clears it from `unreadPanes` -- the bell popover's "jump to that
    /// pane" action.
    func focusUnreadPane(_ pane: UnreadPane) {
        if let workspaceID = pane.workspaceID {
            focusWorkspace(workspaceID, in: pane.sessionID)
        } else {
            select(pane.sessionID)
        }
        unreadPanes.removeAll { $0.paneID == pane.paneID }
    }

    /// Jumps to the next unread pane (see `UnreadPane`) -- the bell
    /// popover's cmux-style "next unread" keybinding. Picks the next
    /// *session* with at least one unread pane (`NextUnreadSessionPlanner`,
    /// reused as-is: sessions, not panes, are what `sessions`/`selectedID`
    /// are ordered over), then focuses that session's first unread pane. A
    /// no-op if nothing is unread.
    func goToNextUnreadSession() {
        let unreadSessionIDs = Set(unreadPanes.map(\.sessionID))
        guard let nextSessionID = NextUnreadSessionPlanner.next(
            after: selectedID,
            sessionOrder: sessions.map(\.id),
            unread: unreadSessionIDs
        ), let pane = unreadPanes.first(where: { $0.sessionID == nextSessionID }) else { return }
        focusUnreadPane(pane)
    }

    /// Clears the currently-selected session's unread pane that herdr last
    /// reported as focused, if any -- called from
    /// `AppDelegate.applicationDidBecomeActive` for responsiveness (the next
    /// `pollAgentStatus` tick would otherwise clear the same entry
    /// opportunistically, just not until the timer/event trigger fires).
    func clearUnreadForSelectedSessionIfAppActive() {
        guard NSApp.isActive, let selectedID, let paneID = lastKnownFocusedPaneID[selectedID] else { return }
        unreadPanes.removeAll { $0.paneID == paneID }
    }

    /// Queries `id`'s workspaces (off the main thread) and publishes the
    /// result into `workspaces`, once, for the sidebar's disclosure to show
    /// when it's first expanded. A target with no workspace analogue, or one
    /// that can't be reliably queried (e.g. herdr `--remote`): no-op. A
    /// failed query leaves any previous value alone rather than flicker to
    /// empty. `WorkspaceFetchPlanner.shouldApply` drops the result if `id`
    /// was closed while the query was in flight.
    func fetchWorkspaces(for id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(session.profile) else { return }
        let sessionName = session.sessionName
        let path = resolvedPATH

        DispatchQueue.global(qos: .userInitiated).async {
            guard let workspaces = WorkspaceQuery.workspaces(
                sessionName: sessionName,
                target: target,
                path: path,
                isCancelled: { [weak self] in self?.isShuttingDown ?? true }
            ) else { return }
            DispatchQueue.main.async {
                guard WorkspaceFetchPlanner.shouldApply(sessionID: id, liveSessionIDs: Set(self.sessions.map(\.id))) else { return }
                self.workspaces[id] = workspaces
            }
        }
    }

    /// Switches `id`'s server to `workspaceID` and brings `id` itself
    /// forward -- the same effect as clicking the session row, scoped to a
    /// specific workspace. The focus command runs off the main thread and is
    /// fire-and-forget: `select` doesn't wait on it, matching how every other
    /// sidebar click behaves.
    func focusWorkspace(_ workspaceID: String, in id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(session.profile) else { return }
        let sessionName = session.sessionName
        let path = resolvedPATH

        // Flip the local `focused` flags immediately -- the CLI switch below
        // is fire-and-forget and fetch-on-expand won't re-query on its own,
        // so without this the sidebar/palette highlight wouldn't move until
        // a manual collapse/re-expand.
        if let current = workspaces[id] {
            workspaces[id] = WorkspaceFocusPlanner.applying(focusing: workspaceID, in: current)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = WorkspaceFocus.focus(
                sessionName: sessionName,
                target: target,
                workspaceID: workspaceID,
                path: path,
                isCancelled: { self?.isShuttingDown ?? true }
            )
        }
        select(id)
    }

    /// Adds a new profile or replaces the existing one with the same id.
    /// Adds a new profile or replaces the existing one with the same id.
    /// Refreshes discovery so a command/arguments/environment edit that
    /// changes this profile's actual target (e.g. adding a remote flag, or
    /// changing which multiplexer it drives) doesn't leave `discovered`
    /// showing results from the profile's previous target until the next
    /// unrelated refresh.
    func upsertProfile(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        refreshDiscovery()
    }

    /// Removes a profile, re-seeding the built-in defaults instead of
    /// leaving (and persisting) an empty list if that was the last one --
    /// see `ProfileDeletionPlanner`. Also refreshes discovery, same reason
    /// as `upsertProfile`.
    func deleteProfile(_ id: Profile.ID) {
        profiles = ProfileDeletionPlanner.afterDeleting(id, from: profiles)
        if defaultProfileID == id { defaultProfileID = nil }
        refreshDiscovery()
    }

    /// Entry point for `KeybindingMatcher`'s "switch to session N" chords
    /// (docs/architecture.md's "The matcher runs in front of every surface"
    /// invariant). `index` is 0-based.
    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index].id)
    }

    /// Documents intent more than it changes behavior in practice:
    /// `SessionStore` is owned by `Stores`, itself owned by `AppDelegate`
    /// for the app's whole lifetime, and nothing calls
    /// `applicationWillTerminate` today, so this `deinit` never actually
    /// runs before process exit -- the timer stops because the process
    /// does. If it did run: `invalidate()` stops the timer, and setting
    /// `isShuttingDown` is polled cooperatively (`isCancelled`) by any
    /// in-flight `BoundedProcessRunner` call, so a helper process started
    /// just before shutdown is terminated rather than left to run to its
    /// own timeout. `terminalSettingsObserver` (the only other owned
    /// subscription) needs no explicit cancellation here -- `AnyCancellable`
    /// cancels itself when it deallocates, which happens immediately after
    /// this body regardless. `herdrEventClients`' entries each have their
    /// own defensive `deinit` (see `HerdrEventStreamClient`) for the same
    /// reason. Nothing here calls `saveWorkspace()`, so
    /// shutdown -- were it ever actually reached -- cannot itself overwrite
    /// the restorable workspace.
    deinit {
        statusTimer?.invalidate()
        isShuttingDown = true
    }
}

extension NSColor {
    /// Parses a `RRGGBB` (or `#RRGGBB`) hex string like the ones in
    /// `GhosttyThemeDefinition.background`. Returns nil for anything else.
    convenience init?(hexString: String?) {
        guard let raw = hexString else { return nil }
        let hex = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    /// True when the color is dark enough that light-on-dark UI reads best over
    /// it -- used to force the sidebar's SwiftUI contrast to match a dark
    /// terminal theme regardless of the app's chrome appearance.
    var isDark: Bool {
        guard let c = usingColorSpace(.sRGB) else { return true }
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma < 0.5
    }
}
