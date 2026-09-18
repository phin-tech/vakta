//
//  Workspace.swift
//  Vakta
//
//  A multiplexer session's sub-session grouping -- herdr workspaces, tmux
//  windows (`vakta#43sg`), zellij tabs -- queried on demand (fetch-on-expand,
//  not a continuous poll -- see `HerdrPreferences`) via the target's
//  `workspaceListArgv`, and switched via `workspaceFocusArgv`. Neutral
//  across backends; `WorkspaceQuery.parse` is the seam a new backend's
//  output parser plugs into (mirroring `SessionDiscovery`'s
//  `parseHerdr`/`parseLines` split). Local sessions only: a saved remote
//  `herdr machine` isn't reachable from this local socket query (`--remote`
//  combined with any subcommand fails outright), so there is no equivalent
//  for those.

import Foundation

struct Workspace: Equatable {
    let id: String
    let label: String
    let focused: Bool
    /// The most recent command exit code reported by the tmux shell hook.
    /// `nil` means no command has completed yet, or the shell integration did
    /// not report a usable value. Herdr workspaces always leave this nil.
    let lastCommandExitCode: Int?

    init(id: String, label: String, focused: Bool, lastCommandExitCode: Int? = nil) {
        self.id = id
        self.label = label
        self.focused = focused
        self.lastCommandExitCode = lastCommandExitCode
    }
}

enum WorkspaceQuery {
    /// Queries `sessionName`'s workspaces on `target`'s server. Returns nil
    /// when the query fails (protocol mismatch, server down, `target` has no
    /// workspace analogue, …) so the caller can leave the disclosure's last
    /// known state alone rather than flash empty.
    static func workspaces(
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> [Workspace]? {
        guard let argv = target.workspaceListArgv(sessionName: sessionName) else { return nil }
        guard let output = ProcessRunner.run(argv, path: path, environment: target.environment, isCancelled: isCancelled)
        else { return nil }
        return parse(output, backend: target.backend)
    }

    /// Dispatches on the target's backend to the matching output parser.
    static func parse(_ output: String, backend: MultiplexerTarget.Backend) -> [Workspace]? {
        switch backend {
        case .herdr: return parseHerdr(output)
        case .tmux: return parseTmux(output)
        }
    }

    /// Minimal shape of herdr's `workspace list` JSON; unknown keys
    /// (`agent_status`, `number`, `tab_count`, `pane_count`, `active_tab_id`,
    /// `worktree`, …) are ignored.
    private static func parseHerdr(_ output: String) -> [Workspace]? {
        guard let data = output.data(using: .utf8) else { return nil }
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        return decoded?.result?.workspaces.map {
            Workspace(id: $0.id, label: $0.label, focused: $0.focused, lastCommandExitCode: nil)
        } // nil for an error payload
    }

    /// `list-windows -F '#{window_id}|#{window_name}|#{window_active}|#{@vakta_last_exit}'`:
    /// one `|`-separated window per line. The first delimiter ends the id;
    /// the final two delimiters end the active flag and optional exit code, so
    /// a window name containing `|` stays intact in the middle field. The
    /// three-field form remains accepted for sessions whose status hook has
    /// not been installed yet.
    private static func parseTmux(_ output: String) -> [Workspace] {
        output.split(separator: "\n").compactMap { line in
            guard let first = line.firstIndex(of: "|") else { return nil }
            let id = line[line.startIndex..<first]
            let afterID = line.index(after: first)
            guard let last = line.lastIndex(of: "|"), first < last else { return nil }

            if let beforeLast = line[..<last].lastIndex(of: "|"), beforeLast > first {
                let activeFlag = line[line.index(after: beforeLast)..<last]
                // A four-field record has an explicit 0/1 active flag before
                // the final status field. A legacy three-field record may
                // contain arbitrary `|` characters in its label, so only that
                // shape is unambiguous enough to decode as the new format.
                if activeFlag == "0" || activeFlag == "1" {
                    let label = line[afterID..<beforeLast]
                    let rawExitCode = line[line.index(after: last)...]
                    return Workspace(
                        id: String(id),
                        label: String(label),
                        focused: activeFlag == "1",
                        lastCommandExitCode: TmuxCommandStatusHook.exitCode(from: rawExitCode)
                    )
                }
            }

            // Compatibility with the original three-field query.
            let label = line[afterID..<last]
            return Workspace(
                id: String(id),
                label: String(label),
                focused: line[line.index(after: last)...] == "1",
                lastCommandExitCode: nil
            )
        }
    }

    private struct Response: Decodable {
        let result: Result?
        struct Result: Decodable { let workspaces: [Wire] }
        /// herdr's own wire shape for one workspace entry.
        struct Wire: Decodable {
            let id: String
            let label: String
            let focused: Bool

            private enum CodingKeys: String, CodingKey {
                case id = "workspace_id"
                case label
                case focused
            }
        }
    }
}

/// Optimistic local update for `SessionStore.focusWorkspace`: the CLI switch
/// runs off the main thread and isn't awaited, and the sidebar/palette only
/// otherwise learn a workspace's `focused` flag from `WorkspaceQuery`, which
/// fetch-on-expand runs once and never repeats -- so without this, the
/// highlight wouldn't move until a manual collapse/re-expand. An unknown
/// `focusing` id (already gone, e.g. closed underneath the click) clears
/// every flag rather than leaving a stale one set.
enum WorkspaceFocusPlanner {
    static func applying(focusing id: String, in workspaces: [Workspace]) -> [Workspace] {
        workspaces.map {
            Workspace(
                id: $0.id,
                label: $0.label,
                focused: $0.id == id,
                lastCommandExitCode: $0.lastCommandExitCode
            )
        }
    }
}

enum WorkspaceFocus {
    /// Switches `sessionName`'s server to `workspaceID`. Returns whether the
    /// command succeeded (nonzero exit, launch failure, or a target with no
    /// workspace analogue all report `false`).
    static func focus(
        sessionName: String,
        target: MultiplexerTarget,
        workspaceID: String,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Bool {
        guard let argv = target.workspaceFocusArgv(sessionName: sessionName, workspaceID: workspaceID) else { return false }
        return ProcessRunner.run(argv, path: path, environment: target.environment, isCancelled: isCancelled) != nil
    }
}

/// Whether a fetch-on-expand `WorkspaceQuery.workspaces` result, which
/// completes asynchronously, is still meaningful to apply -- `false` once
/// the session it was fetched for has been closed while the query was in
/// flight (the single-session analog of `AgentStatusApplyPlanner`/
/// `DiscoveryApplyPlanner`'s live-ID filtering).
enum WorkspaceFetchPlanner {
    static func shouldApply(sessionID: Session.ID, liveSessionIDs: Set<Session.ID>) -> Bool {
        liveSessionIDs.contains(sessionID)
    }
}
