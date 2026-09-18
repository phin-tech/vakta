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
        return decoded?.result?.workspaces.map { Workspace(id: $0.id, label: $0.label, focused: $0.focused) } // nil for an error payload
    }

    /// `list-windows -F '#{window_id}|#{window_name}|#{window_active}'`:
    /// one `|`-separated window per line. Splits only on the *first* and
    /// *last* `|` -- a window name containing `|` stays intact in the
    /// middle field rather than corrupting the split -- and drops a line
    /// with fewer than 2 delimiters rather than failing the whole batch.
    private static func parseTmux(_ output: String) -> [Workspace] {
        output.split(separator: "\n").compactMap { line in
            guard let first = line.firstIndex(of: "|"), let last = line.lastIndex(of: "|"), first < last else { return nil }
            let id = line[line.startIndex..<first]
            let label = line[line.index(after: first)..<last]
            let activeFlag = line[line.index(after: last)...]
            return Workspace(id: String(id), label: String(label), focused: activeFlag == "1")
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
        workspaces.map { Workspace(id: $0.id, label: $0.label, focused: $0.id == id) }
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
