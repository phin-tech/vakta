//
//  SessionStore.swift
//  Vakta
//
//  Owns the session list + selection (ObservableObject, drives the SwiftUI
//  sidebar chrome) and the single shared `TerminalController` (one
//  `ghostty_app_t` for the whole process -- settled design decision #2).
//
//  This type also owns `hostContainer`, the AppKit view every session's
//  surface lives in for the app's lifetime (settled design decision #4). See
//  `TerminalContainer.swift` for why creation/removal/selection are all
//  imperative calls into that view rather than anything SwiftUI-driven.

import AppKit
import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme

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

    /// Whether the sidebar is collapsed to its icon rail. Driven by the
    /// sidebar's own button and the View menu; `AppDelegate` animates the width.
    @Published var sidebarCollapsed = false

    /// Saved workspace records whose profile no longer exists, set once at
    /// startup by `WorkspaceStartupPlanner` and never auto-launched under a
    /// substituted profile. Not surfaced in any UI yet (no recovery flow
    /// exists) -- kept here so one exists to build against, and so this data
    /// isn't simply discarded.
    @Published private(set) var unresolvedWorkspaceRecords: [SessionRecord] = []

    /// Per-session agent status (herdr sessions only), polled from
    /// `herdr agent list` and shown as a colored dot in the sidebar. The Dock
    /// badge (count of sessions needing attention) is derived here so both the
    /// poll and `removeSession` keep it correct with no extra call sites.
    @Published private(set) var agentStatus: [Session.ID: AgentStatus] = [:] {
        didSet { updateDockBadge() }
    }

    /// Repeating poll for `agentStatus`.
    private var statusTimer: Timer?

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

    /// The user's login-shell PATH, resolved once. Injected into every spawned
    /// session so a bare command (e.g. `herdr` in `~/.local/bin`) resolves even
    /// when Vakta was launched from a `.app` with a minimal PATH.
    private let resolvedPATH: String

    private let root: URL

    /// True only while `init` is recreating sessions from a saved workspace.
    /// Suppresses `saveWorkspace()` so restoring N records writes the file
    /// once (via the explicit flush in `init`), or not at all when the
    /// startup plan says not to persist -- not N times, progressively, as
    /// each session is created.
    private var isRestoringWorkspace = false

    /// The profile used when `createSession` is called with no explicit one:
    /// the user's chosen default, else the first profile (else the built-in
    /// herdr profile if the list is somehow empty).
    var defaultProfile: Profile {
        if let id = defaultProfileID, let profile = profiles.first(where: { $0.id == id }) {
            return profile
        }
        return profiles.first ?? .herdr
    }

    init(terminalSettings: TerminalSettingsStore, root: URL) {
        self.terminalSettings = terminalSettings
        self.root = root
        commandOverride = ProcessInfo.processInfo.environment["VAKTA_TERMINAL_COMMAND"]
        resolvedPATH = ShellEnvironment.resolvedPATH()

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

        // Resolve the user's chosen theme (falling back to the wrapper's
        // built-in default if the name ever goes stale) and derive the sidebar
        // colors from it.
        let definition = GhosttyThemeCatalog.theme(named: terminalSettings.themeName)
        let theme = definition?.toTerminalTheme() ?? .default

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

        // Restore the previous workspace: recreate a session per resolved
        // record, each re-attaching (herdr/tmux) to its still-running server
        // session. `isRestoringWorkspace` suppresses `saveWorkspace()` for
        // the duration (each `createSession` below would otherwise call it
        // once per record, progressively rewriting the file with a partial
        // list) -- the plan decides once, up front, whether the end result
        // needs persisting at all. A corrupt/unreadable file is deliberately
        // NOT overwritten with the single-default-session fallback (see
        // `WorkspaceStartupPlanner`).
        let decision = WorkspaceStartupPlanner.plan(
            for: WorkspacePersistence.load(root: root),
            profiles: profiles
        )
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
    /// user's font. ALWAYS emits `keybind = clear` (settled design decision #5)
    /// so a font-only change can't drop it -- `setTerminalConfiguration`
    /// replaces the whole config rather than merging. Empty font family / zero
    /// size are omitted so ghostty keeps its own default.
    private static func configureBuilder(
        _ builder: inout TerminalConfiguration.Builder,
        with settings: TerminalSettings
    ) {
        builder.withCustom("keybind", "clear")
        let family = settings.fontFamily.trimmingCharacters(in: .whitespaces)
        if !family.isEmpty {
            builder.withCustom("font-family", family)
        }
        if settings.fontSize > 0 {
            builder.withCustom("font-size", String(format: "%g", settings.fontSize))
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

        let definition = GhosttyThemeCatalog.theme(named: snapshot.themeName)
        if let theme = definition?.toTerminalTheme() {
            controller.setTheme(theme)
        }
        applyThemeColors(from: definition)
    }

    /// Recomputes the sidebar-matching colors from a theme definition (nil ->
    /// safe dark-neutral fallbacks).
    private func applyThemeColors(from definition: GhosttyThemeDefinition?) {
        terminalBackgroundColor = NSColor(hexString: definition?.background)
            ?? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        terminalSelectionColor = NSColor(hexString: definition?.selectionBackground)
            ?? NSColor(srgbRed: 0.27, green: 0.28, blue: 0.35, alpha: 1)
        terminalAccentColor = NSColor(hexString: definition?.palette[4]) ?? .controlAccentColor
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
    private func pollAgentStatus() {
        var herdrSessions: [(id: Session.ID, name: String, target: MultiplexerTarget)] = []
        for session in sessions {
            guard (session.profile.command as NSString).lastPathComponent == "herdr" else { continue }
            switch LaunchTargetResolver.resolve(session.profile) {
            case .multiplexer(let target):
                herdrSessions.append((session.id, session.sessionName, target))
            case .unsupported:
                agentStatus[session.id] = .unavailable
            }
        }
        guard !herdrSessions.isEmpty else { return }
        let path = resolvedPATH

        DispatchQueue.global(qos: .utility).async {
            var updates: [Session.ID: AgentStatus] = [:]
            for session in herdrSessions {
                if let status = HerdrAgentStatus.status(sessionName: session.name, target: session.target, path: path) {
                    updates[session.id] = status
                }
            }
            DispatchQueue.main.async {
                for (id, status) in updates {
                    let previous = self.agentStatus[id]
                    if previous != status, let session = self.sessions.first(where: { $0.id == id }) {
                        self.notifier.handleTransition(
                            sessionID: id,
                            title: session.displayTitle,
                            from: previous,
                            to: status,
                            isSelected: self.selectedID == id,
                            appActive: NSApp.isActive
                        )
                    }
                    self.agentStatus[id] = status
                }
            }
        }
    }

    /// The Dock badge shows how many sessions are waiting on the user (agent
    /// status `.attention`); cleared when none are.
    private func updateDockBadge() {
        let waiting = agentStatus.values.lazy.filter { $0 == .attention }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    /// Re-queries each multiplexer for its existing sessions (off the main
    /// thread) and republishes `discovered`. Cheap; call on launch and when the
    /// app becomes active so the "New Session" menu is reasonably fresh.
    func refreshDiscovery() {
        let candidates = profiles
        let path = resolvedPATH
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [Profile.ID: DiscoveryResult] = [:]
            for profile in candidates {
                switch LaunchTargetResolver.resolve(profile) {
                case .multiplexer(let target):
                    result[profile.id] = .sessions(SessionDiscovery.names(for: target, path: path))
                case .unsupported:
                    // Only a known-multiplexer profile whose target can't be
                    // reliably queried gets `.unsupported` -- a profile that
                    // isn't a multiplexer at all (e.g. a plain shell) gets no
                    // entry, since there was never anything to discover.
                    if LaunchTargetResolver.isKnownMultiplexerCommand(profile) {
                        result[profile.id] = .unsupported
                    }
                }
            }
            DispatchQueue.main.async { self.discovered = result }
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
        select(session.id)
        saveWorkspace()
        return session
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
        let records = sessions.map { session -> SessionRecord in
            // Only an explicit per-session override is worth pinning to this
            // record -- a value merely inherited from the profile should keep
            // following the profile if it's edited later, so it's persisted
            // as `nil` (restore re-resolves it from the profile) rather than
            // baked in as if the user had chosen it.
            let inheritedFromProfile = profiles.first { $0.id == session.profile.id }?.workingDirectory
            let explicitOverride = session.profile.workingDirectory == inheritedFromProfile
                ? nil
                : session.profile.workingDirectory
            return SessionRecord(
                profileID: session.profile.id,
                sessionName: session.sessionName,
                customName: session.customName,
                workingDirectory: explicitOverride
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
    /// actually closed.
    func requestClose(_ id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // TODO(verify): "close_surface" is presumed to be the upstream
        // Ghostty binding-action name for this (mirrors the app menu /
        // Cmd+W action in the reference apps). `performBindingAction` only
        // forwards the string to `ghostty_surface_binding_action`; the
        // table of valid action names lives in upstream Ghostty's Zig
        // source, not in this Swift wrapper, so this was not re-derived
        // from the resolved package checkout the way the rest of this file
        // was.
        _ = session.viewState.performBindingAction("close_surface")
    }

    private func removeSession(_ id: Session.ID, processAlive: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        hostContainer.removeSession(id)
        agentStatus[id] = nil
        saveWorkspace()

        guard selectedID == id else { return }
        let fallbackIndex = min(index, sessions.count - 1)
        if sessions.indices.contains(fallbackIndex) {
            select(sessions[fallbackIndex].id)
        } else {
            selectedID = nil
        }
    }

    func select(_ id: Session.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        hostContainer.select(id)
        saveWorkspace()
    }

    /// Adds a new profile or replaces the existing one with the same id.
    func upsertProfile(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Removes a profile. The list never goes empty -- `defaultProfile` falls
    /// back to `.herdr` -- so removing the last one is harmless.
    func deleteProfile(_ id: Profile.ID) {
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id { defaultProfileID = nil }
    }

    /// Entry point for `KeybindingMatcher`'s "switch to session N" chords
    /// (settled design decision #6). `index` is 0-based.
    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index].id)
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
