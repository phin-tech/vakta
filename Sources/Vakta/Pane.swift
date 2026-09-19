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
        guard let argv = target.paneListArgv(sessionName: sessionName, workspaceID: workspaceID),
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
                status: status
            )
        }
    }

    /// Format: pane id, window/tab id, title, active flag. The first two
    /// delimiters identify the pane and tab; the final delimiter identifies
    /// focus, so a `|` inside a pane title remains data.
    private static func parseTmux(_ output: String) -> [Pane] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let first = line.firstIndex(of: "|"),
                  let second = line[line.index(after: first)...].firstIndex(of: "|"),
                  let last = line.lastIndex(of: "|"),
                  second < last
            else { return nil }

            let id = String(line[..<first])
            let tabStart = line.index(after: first)
            let tabID = String(line[tabStart..<second])
            let labelStart = line.index(after: second)
            let label = String(line[labelStart..<last])
            let active = line[line.index(after: last)...]
            guard !id.isEmpty, !tabID.isEmpty, active == "0" || active == "1" else { return nil }

            return Pane(
                id: id,
                tabID: tabID,
                label: label.isEmpty ? id : label,
                focused: active == "1",
                status: .none
            )
        }
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

            private enum CodingKeys: String, CodingKey {
                case agent
                case agentStatus = "agent_status"
                case paneID = "pane_id"
                case tabID = "tab_id"
                case label
                case terminalTitle = "terminal_title"
                case terminalTitleStripped = "terminal_title_stripped"
                case focused
            }
        }
    }
}
