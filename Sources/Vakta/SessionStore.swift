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
        didSet { ProfilePersistence.save(profiles) }
    }

    /// One `ghostty_app_t` for the whole process. Every `Session` this store
    /// creates is handed this same controller.
    let controller: TerminalController

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

    /// The profile used when `createSession` is called with no explicit one.
    var defaultProfile: Profile { profiles.first ?? .herdr }

    init() {
        commandOverride = ProcessInfo.processInfo.environment["VAKTA_TERMINAL_COMMAND"]
        resolvedPATH = ShellEnvironment.resolvedPATH()

        // Load saved profiles; first launch (or an unreadable file) seeds the
        // built-ins and writes them. Assigning `profiles` in init does not
        // fire its `didSet`, so the first-run seed is saved explicitly.
        let loaded = ProfilePersistence.load()
        let seeded = loaded ?? [.herdr, .tmux, .shell]
        profiles = seeded
        if loaded == nil {
            ProfilePersistence.save(seeded)
        }

        // A theme is optional polish, not a settled requirement, but
        // GhosttyTheme is a settled dependency (product list in the task),
        // so it gets at least this much real use: look up a bundled
        // iTerm2-Color-Schemes theme and fall back to the wrapper's
        // built-in default if the name ever goes stale.
        let theme = GhosttyThemeCatalog.theme(named: "Dracula")?.toTerminalTheme() ?? .default

        controller = TerminalController(theme: theme) { builder in
            // Settled design decision #5: ALL keys pass through to herdr.
            // `keybind = clear` removes every libghostty default binding so
            // nothing is consumed before the key reaches the pty. Vakta's
            // own "switch session N" chord is intercepted earlier still, in
            // `KeybindingMatcher`, before this config or the surface ever
            // see the NSEvent.
            builder.withCustom("keybind", "clear")
        }

        // Restore the previous workspace: recreate a session per saved record,
        // each re-attaching (herdr/tmux) to its still-running server session.
        // Nothing saved (first launch) -> one default session.
        let records = WorkspacePersistence.load() ?? []
        if records.isEmpty {
            createSession()
        } else {
            for record in records {
                let profile = profiles.first { $0.id == record.profileID } ?? defaultProfile
                createSession(
                    profile: profile,
                    sessionName: record.sessionName,
                    customName: record.customName
                )
            }
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
        WorkspacePersistence.save(sessions.map {
            SessionRecord(
                profileID: $0.profile.id,
                sessionName: $0.sessionName,
                customName: $0.customName
            )
        })
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
    }

    /// Entry point for `KeybindingMatcher`'s "switch to session N" chords
    /// (settled design decision #6). `index` is 0-based.
    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index].id)
    }
}
