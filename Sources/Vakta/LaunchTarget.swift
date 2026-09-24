//
//  LaunchTarget.swift
//  Vakta
//
//  What server a profile's discovery/status queries and attach identity
//  actually point at, resolved from the profile alone (pure -- no process
//  execution). `SessionDiscovery` and `HerdrAgentStatus` consume a resolved
//  `MultiplexerTarget` instead of re-deriving "herdr"/"tmux" from scratch
//  and running the bare binary name with no environment.
//
//  Previously: `SessionDiscovery`/`HerdrAgentStatus` invoked bare `herdr`/
//  `tmux` with only PATH+HOME, discarding `profile.command`'s actual path,
//  `profile.environment` (e.g. `HERDR_SOCKET_PATH`, which selects which
//  local herdr server a command talks to), and any server-selecting flags
//  in `profile.arguments`. A remote herdr profile (`--remote host --session
//  {name}`) would silently query the LOCAL herdr server instead -- `herdr
//  session list` has no per-invocation remote flag at all, so there is no
//  reliable local query for "what's actually on that remote server."

import Foundation

enum LaunchTarget: Equatable {
    case multiplexer(MultiplexerTarget)
    /// The profile's command isn't a known multiplexer, or its arguments
    /// make the actual server ambiguous/unreachable from a locally-run
    /// query. Distinct from "queried, found nothing" -- see
    /// `SessionStore.DiscoveryResult`.
    case unsupported
}

struct MultiplexerTarget: Equatable {
    enum Backend: Equatable {
        case herdr
        case tmux
    }

    var backend: Backend
    /// `profile.command` verbatim -- an absolute/custom-named binary is
    /// honored rather than a hardcoded `"herdr"`/`"tmux"` literal.
    var executable: String
    /// A custom tmux socket *path* (`-S <path>` in the profile's arguments),
    /// if any. `nil` uses tmux's default socket. Mutually exclusive with
    /// `tmuxSocketName` in practice (tmux itself rejects both together);
    /// `LaunchTargetResolver` prefers whichever flag it finds first.
    var tmuxSocketPath: String?
    /// A custom tmux socket *name* (`-L <name>`, under tmux's default socket
    /// directory), if any -- tmux's other, more common way to address a
    /// distinct server instance.
    var tmuxSocketName: String?
    /// `profile.environment` verbatim, applied on top of PATH/HOME for
    /// every discovery/status query against this target -- e.g. a profile
    /// that sets `HERDR_SOCKET_PATH` to address a specific local herdr
    /// server instance.
    var environment: [String: String]

    /// The argv to list this target's existing sessions.
    var discoveryArgv: [String] {
        switch backend {
        case .herdr:
            return [executable, "session", "list"]
        case .tmux:
            return tmuxArgv(["list-sessions", "-F", "#{session_name}"])
        }
    }

    /// `[executable, -S/-L flag if any, ...trailingArgs]` -- the socket
    /// addressing every tmux subcommand needs, factored out so
    /// `discoveryArgv`/`workspaceListArgv`/`workspaceFocusArgv` can't drift
    /// on how they honor a custom socket.
    private func tmuxArgv(_ trailingArgs: [String]) -> [String] {
        var argv = [executable]
        if let tmuxSocketPath {
            argv += ["-S", tmuxSocketPath]
        } else if let tmuxSocketName {
            argv += ["-L", tmuxSocketName]
        }
        argv += trailingArgs
        return argv
    }

    /// The argv to query agent status for `sessionName`, or `nil` for a
    /// backend with no equivalent (only herdr has agents).
    func statusArgv(sessionName: String) -> [String]? {
        guard backend == .herdr else { return nil }
        return [executable, "--session", sessionName, "agent", "list"]
    }

    /// The argv to list `sessionName`'s workspaces (herdr workspaces; tmux
    /// windows, its workspace analogue -- `#{window_id}`, `#{window_name}`,
    /// `#{window_active}` `|`-separated, one per line, parsed by
    /// `WorkspaceQuery.parse`), or `nil` for a backend with no equivalent.
    /// The delimiter is a plain printable character, not a tab: confirmed
    /// live that tmux's `-F` engine substitutes "unprintable" bytes
    /// (including tab) with `_` whenever it can't detect a UTF-8 locale --
    /// which every invocation here can't, since `ProcessRunner` deliberately
    /// sets only `PATH`/`HOME`, no `LANG`/`LC_ALL` (see `ProcessRunner.run`).
    func workspaceListArgv(sessionName: String) -> [String]? {
        switch backend {
        case .herdr:
            return [executable, "--session", sessionName, "workspace", "list"]
        case .tmux:
            return tmuxArgv([
                "list-windows", "-t", sessionName, "-F",
                "#{window_id}|#{window_name}|#{window_active}|#{\(TmuxCommandStatusHook.optionName)}"
            ])
        }
    }

    /// The argv to persist a command exit code on the tmux session's current
    /// window. Keeping the lookup and write in one tmux invocation avoids a
    /// stale window id when the user changes windows between subprocesses.
    /// The shell integration callback is delivered for the attached session,
    /// so its current window is the only identity available at this boundary.
    func setActiveWorkspaceCommandStatusArgv(
        sessionName: String,
        exitCode: Int
    ) -> [String]? {
        switch backend {
        case .herdr:
            return nil
        case .tmux:
            return tmuxArgv([
                "set-window-option", "-t", sessionName,
                TmuxCommandStatusHook.optionName, "\(exitCode)"
            ])
        }
    }

    /// The `-F` format for tmux pane listings, parsed by `PaneQuery.parse`:
    /// pane id, window id, active flag, current path, title, separated by
    /// `\u{1f}` (title last). Pane listings pass `-u`: confirmed live against
    /// tmux 3.7b that without a UTF-8 locale -- which `ProcessRunner`'s
    /// PATH/HOME-only environment never has -- tmux rewrites both the
    /// separator and non-ASCII path bytes to `_` (`…/café` became `…/caf_`).
    static let tmuxPaneFormat = tmuxPaneFormat(activeFlag: "#{pane_active}")

    /// `tmuxPaneFormat` for a session-wide listing: the focus flag is set
    /// only for the active window's active pane, so exactly one pane is
    /// focused per session -- as herdr reports -- rather than one per window.
    static let tmuxSessionPaneFormat = tmuxPaneFormat(activeFlag: "#{&&:#{pane_active},#{window_active}}")

    private static func tmuxPaneFormat(activeFlag: String) -> String {
        ["#{pane_id}", "#{window_id}", activeFlag, "#{pane_current_path}", "#{pane_title}"].joined(separator: "\u{1f}")
    }

    /// The argv to list the panes in `workspaceID`, or `nil` for a backend
    /// with no equivalent. Herdr returns JSON; tmux returns one record per
    /// pane in `tmuxPaneFormat` for `PaneQuery.parse`.
    func paneListArgv(sessionName: String, workspaceID: String) -> [String]? {
        switch backend {
        case .herdr:
            return [executable, "--session", sessionName, "pane", "list", "--workspace", workspaceID]
        case .tmux:
            return tmuxArgv(["-u", "list-panes", "-t", "\(sessionName):\(workspaceID)", "-F", Self.tmuxPaneFormat])
        }
    }

    /// The argv to list every pane in `sessionName` across all of its
    /// workspaces, in the same output shape as `paneListArgv`; at most one
    /// pane -- the session's focused one -- reports `focused`.
    func sessionPaneListArgv(sessionName: String) -> [String]? {
        switch backend {
        case .herdr:
            return [executable, "--session", sessionName, "pane", "list"]
        case .tmux:
            return tmuxArgv(["-u", "list-panes", "-s", "-t", sessionName, "-F", Self.tmuxSessionPaneFormat])
        }
    }

    /// The argv to focus `paneID` directly, or `nil` when the backend's CLI
    /// does not expose direct pane focus. Herdr's current CLI only exposes
    /// directional focus; its exact-pane path uses the socket API adapter.
    func paneFocusArgv(sessionName: String, workspaceID: String, paneID: String) -> [String]? {
        switch backend {
        case .herdr:
            return nil
        case .tmux:
            return tmuxArgv(["select-pane", "-t", paneID])
        }
    }

    /// The argv to focus `workspaceID` on `sessionName`, or `nil` for a
    /// backend with no equivalent. tmux's own "bring the session forward"
    /// step is `switch-client`, but that targets the *invoking* client's
    /// session -- there is none here (this runs as a detached subprocess,
    /// not from inside a tmux client), so it fails with "no current client"
    /// and would poison the whole chained command (confirmed against a
    /// throwaway tmux 3.7b server). `select-window` alone still changes
    /// which window is active for whichever client later attaches; bringing
    /// the Vakta session itself forward is `SessionStore.focusWorkspace`'s
    /// own `select(id)` call, not this argv's job.
    func workspaceFocusArgv(sessionName: String, workspaceID: String) -> [String]? {
        switch backend {
        case .herdr:
            return [executable, "--session", sessionName, "workspace", "focus", workspaceID]
        case .tmux:
            return tmuxArgv(["select-window", "-t", "\(sessionName):\(workspaceID)"])
        }
    }

    /// The argv to find the currently focused pane's working directory, for
    /// "Open in Editor" (`ActivePaneWorkingDirectoryQuery`). herdr's `pane
    /// current` reports the server's own notion of "current" pane -- exactly
    /// one `focused: true` pane per session, confirmed live against a
    /// running session with a scrubbed PATH/HOME-only environment (no
    /// `--pane`/tty dependence). tmux's `display-message` targets the
    /// session's current window's active pane, tmux's closest equivalent.
    func activePaneWorkingDirectoryArgv(sessionName: String) -> [String]? {
        switch backend {
        case .herdr:
            return [executable, "--session", sessionName, "pane", "current"]
        case .tmux:
            return tmuxArgv(["display-message", "-p", "-t", sessionName, "#{pane_current_path}"])
        }
    }

    /// The Unix socket to subscribe an event stream to for `sessionName`, or
    /// `nil` for a backend with no equivalent (only herdr has one; tmux
    /// control mode is out of scope for this epic -- see
    /// docs/multiplexer-backends.md).
    func eventStreamSocketPath(sessionName: String, configDirectory: URL = HerdrSocketPath.defaultConfigDirectory()) -> URL? {
        guard backend == .herdr else { return nil }
        return HerdrSocketPath.resolve(sessionName: sessionName, configDirectory: configDirectory)
    }

    /// The argv to perform a mutating layout/session `action`, or `nil` for a
    /// backend with no equivalent. herdr addresses a pane/workspace by its
    /// opaque id positionally (mirroring `workspace focus <id>`); tmux
    /// qualifies a window as `<session>:<window>` and a pane by its own id.
    /// `splitPane` focuses the new pane (herdr `--focus`; tmux focuses it by
    /// default). `resizePane` bakes a per-backend step because the two
    /// backends' resize units are incompatible (herdr a split-ratio delta,
    /// tmux whole cells) -- see `ResizeDirection`.
    func actionArgv(sessionName: String, _ action: MultiplexerAction) -> [String]? {
        switch backend {
        case .herdr:
            let base = [executable, "--session", sessionName]
            switch action {
            case let .splitPane(paneID, direction):
                return base + ["pane", "split", "--pane", paneID, "--direction", herdrSplitDirection(direction), "--focus"]
            case let .closePane(paneID):
                return base + ["pane", "close", paneID]
            case let .focusPane(paneID, direction):
                return base + ["pane", "focus", "--pane", paneID, "--direction", herdrFocusDirection(direction)]
            case let .zoomPane(paneID):
                return base + ["pane", "zoom", "--pane", paneID]
            case let .resizePane(paneID, direction):
                return base + ["pane", "resize", "--pane", paneID, "--direction", herdrResizeDirection(direction), "--amount", Self.herdrResizeStep]
            case let .renamePane(paneID, label):
                return base + ["pane", "rename", paneID, label]
            case let .closeWorkspace(workspaceID):
                return base + ["workspace", "close", workspaceID]
            case let .createWorkspace(label):
                return base + ["workspace", "create"] + (label.map { ["--label", $0] } ?? [])
            case let .renameWorkspace(workspaceID, label):
                return base + ["workspace", "rename", workspaceID, label]
            case .stopSession:
                // `session stop <name>` names which session to stop; it is not
                // the `--session` addressing used to run *inside* a session.
                return [executable, "session", "stop", sessionName]
            }
        case .tmux:
            switch action {
            case let .splitPane(paneID, direction):
                return tmuxArgv(["split-window", tmuxSplitFlag(direction), "-t", paneID])
            case let .closePane(paneID):
                return tmuxArgv(["kill-pane", "-t", paneID])
            case let .focusPane(paneID, direction):
                return tmuxArgv(["select-pane", "-t", paneID, tmuxFocusFlag(direction)])
            case let .zoomPane(paneID):
                return tmuxArgv(["resize-pane", "-Z", "-t", paneID])
            case let .resizePane(paneID, direction):
                return tmuxArgv(["resize-pane", "-t", paneID, tmuxResizeFlag(direction), Self.tmuxResizeStep])
            case let .renamePane(paneID, label):
                return tmuxArgv(["select-pane", "-t", paneID, "-T", label])
            case let .closeWorkspace(workspaceID):
                return tmuxArgv(["kill-window", "-t", "\(sessionName):\(workspaceID)"])
            case let .createWorkspace(label):
                return tmuxArgv(["new-window", "-t", sessionName] + (label.map { ["-n", $0] } ?? []))
            case let .renameWorkspace(workspaceID, label):
                return tmuxArgv(["rename-window", "-t", "\(sessionName):\(workspaceID)", label])
            case .stopSession:
                return tmuxArgv(["kill-session", "-t", sessionName])
            }
        }
    }

    /// herdr `--amount` is a split-ratio delta; tmux resize is in cells.
    private static let herdrResizeStep = "0.05"
    private static let tmuxResizeStep = "5"

    private func herdrFocusDirection(_ direction: PaneFocusDirection) -> String {
        switch direction {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }

    private func tmuxFocusFlag(_ direction: PaneFocusDirection) -> String {
        switch direction {
        case .left: return "-L"
        case .right: return "-R"
        case .up: return "-U"
        case .down: return "-D"
        }
    }

    private func herdrSplitDirection(_ direction: SplitDirection) -> String {
        switch direction {
        case .right: return "right"
        case .down: return "down"
        }
    }

    private func tmuxSplitFlag(_ direction: SplitDirection) -> String {
        switch direction {
        case .right: return "-h"
        case .down: return "-v"
        }
    }

    private func herdrResizeDirection(_ direction: ResizeDirection) -> String {
        switch direction {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }

    private func tmuxResizeFlag(_ direction: ResizeDirection) -> String {
        switch direction {
        case .left: return "-L"
        case .right: return "-R"
        case .up: return "-U"
        case .down: return "-D"
        }
    }
}

/// The outcome of querying (or not attempting to query) a profile's server
/// for existing sessions. See `SessionStore.discovered`, which is keyed by
/// this type.
enum DiscoveryResult: Equatable {
    case unsupported
    case sessions([String])
}

/// The outcome of deciding whether to poll `pollAgentStatus` for a session,
/// derived purely from its profile -- no process execution. `.skip` covers
/// both "resolved, but this backend has no status query" (tmux) and "not a
/// multiplexer at all" (plain shell): neither should poll or mark the
/// session unavailable.
enum AgentStatusPollOutcome: Equatable {
    case poll(MultiplexerTarget)
    case unavailable
    case skip
}

enum LaunchTargetResolver {
    static func resolve(_ profile: Profile) -> LaunchTarget {
        guard let backend = backend(of: profile.command) else { return .unsupported }
        if backend == .herdr, referencesRemoteFlag(profile.arguments) { return .unsupported }
        return .multiplexer(MultiplexerTarget(
            backend: backend,
            executable: profile.command,
            tmuxSocketPath: backend == .tmux ? tmuxToken("-S", in: profile.arguments) : nil,
            tmuxSocketName: backend == .tmux ? tmuxToken("-L", in: profile.arguments) : nil,
            environment: profile.environment
        ))
    }

    /// Whether `profile`'s command is a multiplexer Vakta knows about at
    /// all, independent of whether its specific target is queryable. Lets a
    /// caller distinguish "not a multiplexer, nothing to show" (a plain
    /// shell profile) from "a multiplexer, but this one's target can't be
    /// reliably queried" (`resolve` returning `.unsupported` for a herdr
    /// `--remote` profile) -- see `SessionStore.DiscoveryResult`.
    static func isKnownMultiplexerCommand(_ profile: Profile) -> Bool {
        backend(of: profile.command) != nil
    }

    /// Whether `profile`'s resolved target has a workspace analogue to
    /// disclose (sidebar triangle, ⌘K rows) -- the single capability check
    /// both `SidebarView` and `AppDelegate` defer to, so they cannot drift
    /// out of sync on which backends qualify. `sessionName` only ever
    /// changes what `workspaceListArgv` would send in that session's own
    /// query, never whether it's `nil`, but threading the real name keeps
    /// the capability check honest about what it's actually asking.
    static func supportsWorkspaces(_ profile: Profile, sessionName: String) -> Bool {
        guard case .multiplexer(let target) = resolve(profile) else { return false }
        return target.workspaceListArgv(sessionName: sessionName) != nil
    }

    /// Whether `profile`'s resolved target can perform mutating layout/session
    /// actions (split, close, zoom, workspace create/rename/close) -- the
    /// single capability check the sidebar context menu and ⌘K action rows
    /// defer to, so they cannot drift on which backends qualify. Uses
    /// `closeWorkspace` as the representative action; every backend that vends
    /// a workspace analogue can close one. A plain shell and a herdr `--remote`
    /// profile (whose server can't be reliably reached from a local query)
    /// both return `false`.
    static func supportsActions(_ profile: Profile, sessionName: String) -> Bool {
        guard case .multiplexer(let target) = resolve(profile) else { return false }
        return target.actionArgv(sessionName: sessionName, .closeWorkspace(workspaceID: "")) != nil
    }

    /// Whether `pollAgentStatus` should poll `profile`'s resolved target for
    /// agent status, skip it, or mark it `.unavailable` (a known multiplexer
    /// whose specific target can't be reliably queried, e.g. herdr
    /// `--remote` -- distinguishing that from "queried, no agents" is the
    /// whole reason `.unavailable` exists; see `vsn0`).
    static func agentStatusPollOutcome(for profile: Profile, sessionName: String) -> AgentStatusPollOutcome {
        switch resolve(profile) {
        case .multiplexer(let target):
            guard target.statusArgv(sessionName: sessionName) != nil else { return .skip }
            return .poll(target)
        case .unsupported:
            return isKnownMultiplexerCommand(profile) ? .unavailable : .skip
        }
    }

    private static func backend(of command: String) -> MultiplexerTarget.Backend? {
        switch (command as NSString).lastPathComponent {
        case "herdr": return .herdr
        case "tmux": return .tmux
        default: return nil
        }
    }

    /// herdr's `--remote <ssh-target>` attaches through SSH to a different
    /// server entirely; `herdr session list` has no per-invocation remote
    /// flag, so there is no way to query that server's session list from
    /// here.
    private static func referencesRemoteFlag(_ arguments: String) -> Bool {
        arguments.split(separator: " ").contains("--remote")
    }

    /// A `<flag> <value>` token pair (`-S <path>` or `-L <name>`, tmux's two
    /// custom-socket flags). Simple whitespace splitting, matching the
    /// space-separated flag convention every documented/built-in profile
    /// already uses -- a quoted value in the template isn't recognized.
    private static func tmuxToken(_ flag: String, in arguments: String) -> String? {
        let tokens = arguments.split(separator: " ").map(String.init)
        guard let index = tokens.firstIndex(of: flag), tokens.indices.contains(index + 1) else { return nil }
        return tokens[index + 1]
    }
}
