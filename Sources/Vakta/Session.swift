//
//  Session.swift
//  Vakta
//
//  One herdr session.
//
//  Settled design decision #2: one `ghostty_app_t` per process, one
//  `ghostty_surface_t` per session. The `ghostty_app_t` lives inside the
//  single, shared `TerminalController` every `Session` is handed (see
//  `SessionStore`); the `ghostty_surface_t` is created lazily by
//  `GhosttyTerminal` the moment this session's `AppTerminalView` attaches to
//  a window (see `TerminalContainer.swift`), and lives exactly as long as
//  that view does.

import Foundation
import GhosttyTerminal

@MainActor
final class Session: Identifiable, ObservableObject {
    let id = UUID()
    let createdAt = Date()

    /// A user-set name that overrides both the profile name and the live shell
    /// title. `nil`/empty means "fall back" (see `displayTitle`). `@Published`
    /// so a sidebar row re-renders the moment it's renamed.
    @Published var customName: String?

    /// Shared across every session in the app -- one `ghostty_app_t`.
    let controller: TerminalController

    /// The profile this session was spawned from -- its base command,
    /// working directory, and environment. See `Profile`.
    let profile: Profile

    /// The multiplexer session name (e.g. `vakta-3f9c1a2b`), substituted for
    /// `{name}` in the profile's arguments. Stable for the life of the session
    /// and persisted, so a restart re-attaches to the same herdr/tmux session.
    let sessionName: String

    /// `backend = .exec` (the default): libghostty spawns and owns the pty
    /// and the child process directly. Settled design decision #3 -- Vakta
    /// never calls `posix_openpt`/`fork` itself. Derived from `profile`.
    let options: TerminalSurfaceOptions

    /// The wrapper's SwiftUI/AppKit state container. It is also the
    /// `TerminalSurfaceViewDelegate` this session's view reports to (title,
    /// close, pwd, bell, ... -- see `TerminalViewState+Delegate.swift` in
    /// the resolved libghostty-spm checkout), so `SidebarView` can simply
    /// observe it for the row label.
    let viewState: TerminalViewState

    /// A one-off session (the tour's installer) that is never saved to the
    /// workspace, so a restart doesn't relaunch it.
    let isTransient: Bool

    init(
        controller: TerminalController,
        profile: Profile,
        sessionName: String,
        customName: String? = nil,
        isTransient: Bool = false
    ) {
        self.controller = controller
        self.profile = profile
        self.sessionName = sessionName
        self.customName = customName
        self.isTransient = isTransient
        self.options = profile.makeSurfaceOptions(sessionName: sessionName)
        self.viewState = TerminalViewState(controller: controller)
    }

    /// A fresh, filesystem/session-safe multiplexer name.
    static func makeSessionName() -> String {
        "vakta-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Resolution order: a user rename wins; otherwise the live shell title
    /// (OSC 2 / OSC 0, wired by the wrapper to `TerminalViewState.title`);
    /// otherwise the profile name while no title has arrived yet.
    var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        return viewState.title.isEmpty ? profile.name : viewState.title
    }
}
