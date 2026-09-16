//
//  HerdrWorkspace.swift
//  Vakta
//
//  A herdr session's workspaces, queried on demand (fetch-on-expand, not a
//  continuous poll -- see `HerdrPreferences`) via `herdr --session <name>
//  workspace list`, and switched via `herdr --session <name> workspace
//  focus <id>`. Local sessions only: a saved remote `herdr machine` isn't
//  reachable from this local socket query (`--remote` combined with any
//  subcommand fails outright), so there is no equivalent for those.

import Foundation

struct HerdrWorkspace: Decodable, Equatable {
    let id: String
    let label: String
    let focused: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "workspace_id"
        case label
        case focused
    }
}

enum HerdrWorkspaceQuery {
    /// Queries `sessionName`'s workspaces on `target`'s server. Returns nil
    /// when the query fails (protocol mismatch, server down, `target` isn't
    /// herdr, …) so the caller can leave the disclosure's last known state
    /// alone rather than flash empty.
    static func workspaces(
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> [HerdrWorkspace]? {
        guard let argv = target.workspaceListArgv(sessionName: sessionName) else { return nil }
        guard let output = ProcessRunner.run(argv, path: path, environment: target.environment, isCancelled: isCancelled)
        else { return nil }
        return parse(output)
    }

    /// Minimal shape of the `workspace list` JSON; unknown keys (`agent_status`,
    /// `number`, `tab_count`, `pane_count`, `active_tab_id`, `worktree`, …)
    /// are ignored.
    static func parse(_ output: String) -> [HerdrWorkspace]? {
        guard let data = output.data(using: .utf8) else { return nil }
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        return decoded?.result?.workspaces // nil for an error payload
    }

    private struct Response: Decodable {
        let result: Result?
        struct Result: Decodable { let workspaces: [HerdrWorkspace] }
    }
}

enum HerdrWorkspaceFocus {
    /// Switches `sessionName`'s server to `workspaceID`. Returns whether the
    /// command succeeded (nonzero exit, launch failure, or a non-herdr
    /// target all report `false`).
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

/// Whether a fetch-on-expand `HerdrWorkspaceQuery.workspaces` result, which
/// completes asynchronously, is still meaningful to apply -- `false` once
/// the session it was fetched for has been closed while the query was in
/// flight (the single-session analog of `AgentStatusApplyPlanner`/
/// `DiscoveryApplyPlanner`'s live-ID filtering).
enum HerdrWorkspaceFetchPlanner {
    static func shouldApply(sessionID: Session.ID, liveSessionIDs: Set<Session.ID>) -> Bool {
        liveSessionIDs.contains(sessionID)
    }
}
