//
//  Pane.swift
//  Vakta
//
//  Backend-neutral pane discovery for the hierarchical command palette.
//  Unlike agent status polling, this includes ordinary shell panes too.

import Foundation

struct Pane: Equatable {
    let id: String
    let tabID: String
    let label: String
    let focused: Bool
    let status: AgentStatus
    /// The workspace containing the pane (herdr `workspace_id`, tmux window
    /// id), so a session-wide listing can still be grouped per workspace.
    var workspaceID: String? = nil
    /// The pane's current directory: herdr's foreground process directory
    /// when reported (e.g. inside vim), else the shell's; tmux's
    /// `pane_current_path`. `nil` when the backend reports none.
    var workingDirectory: String? = nil
}

enum PaneQuery {
    /// Queries the panes in one workspace using the target's executable and
    /// environment. The caller owns dispatching this off the main actor.
    static func panes(
        sessionName: String,
        target: MultiplexerTarget,
        workspaceID: String,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> [Pane]? {
        run(target.paneListArgv(sessionName: sessionName, workspaceID: workspaceID), target: target, path: path, isCancelled: isCancelled)
    }

    /// Queries every pane in `sessionName`, across all of its workspaces.
    static func panes(
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> [Pane]? {
        run(target.sessionPaneListArgv(sessionName: sessionName), target: target, path: path, isCancelled: isCancelled)
    }

    private static func run(
        _ argv: [String]?,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool
    ) -> [Pane]? {
        guard let argv,
              let output = ProcessRunner.run(
                  argv,
                  path: path,
                  environment: target.environment,
                  isCancelled: isCancelled
              )
        else { return nil }
        return parse(output, backend: target.backend)
    }

    /// Parses the output of a backend's pane-list command. A Herdr protocol
    /// failure is nil so callers can preserve a previous result; malformed
    /// tmux lines are dropped independently so one bad pane does not hide the
    /// rest of a window.
    static func parse(_ output: String, backend: MultiplexerTarget.Backend) -> [Pane]? {
        switch backend {
        case .herdr:
            return parseHerdr(output)
        case .tmux:
            return parseTmux(output)
        }
    }

    private static func parseHerdr(_ output: String) -> [Pane]? {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let panes = response.result?.panes
        else { return nil }

        return panes.compactMap { pane in
            guard let paneID = pane.paneID else { return nil }
            let status: AgentStatus
            if pane.agent != nil, let rawStatus = pane.agentStatus {
                status = AgentStatus(herdr: rawStatus)
            } else {
                status = .none
            }
            let label = pane.label.flatMap { $0.isEmpty ? nil : $0 }
                ?? pane.terminalTitleStripped
                ?? pane.terminalTitle
                ?? paneID
            return Pane(
                id: paneID,
                tabID: pane.tabID ?? "",
                label: label,
                focused: pane.focused ?? false,
                status: status,
                workspaceID: pane.workspaceID,
                workingDirectory: nonEmpty(pane.foregroundCwd) ?? nonEmpty(pane.cwd)
            )
        }
    }

    /// Format: `MultiplexerTarget.tmuxPaneFormat` -- pane id, window id,
    /// active flag, current path, title, `\u{1f}`-separated. The title is
    /// last and the split is bounded, so a title containing the separator
    /// stays intact; tmux is run with `-u` so neither the separator nor a
    /// non-ASCII path is rewritten to `_`.
    private static func parseTmux(_ output: String) -> [Pane] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5 else { return nil }

            let id = String(fields[0])
            let windowID = String(fields[1])
            let active = fields[2]
            let path = String(fields[3])
            let label = String(fields[4])
            guard !id.isEmpty, !windowID.isEmpty, active == "0" || active == "1" else { return nil }

            return Pane(
                id: id,
                tabID: windowID,
                label: label.isEmpty ? id : label,
                focused: active == "1",
                status: .none,
                workspaceID: windowID,
                workingDirectory: path.isEmpty ? nil : path
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private struct Response: Decodable {
        let result: Result?

        struct Result: Decodable {
            let panes: [Wire]

            private enum CodingKeys: String, CodingKey { case panes }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                panes = try container.decodeIfPresent([Wire].self, forKey: .panes) ?? []
            }
        }

        struct Wire: Decodable {
            let agent: String?
            let agentStatus: String?
            let paneID: String?
            let tabID: String?
            let label: String?
            let terminalTitle: String?
            let terminalTitleStripped: String?
            let focused: Bool?
            let workspaceID: String?
            let cwd: String?
            let foregroundCwd: String?

            private enum CodingKeys: String, CodingKey {
                case agent
                case agentStatus = "agent_status"
                case paneID = "pane_id"
                case tabID = "tab_id"
                case label
                case terminalTitle = "terminal_title"
                case terminalTitleStripped = "terminal_title_stripped"
                case focused
                case workspaceID = "workspace_id"
                case cwd
                case foregroundCwd = "foreground_cwd"
            }
        }
    }
}
