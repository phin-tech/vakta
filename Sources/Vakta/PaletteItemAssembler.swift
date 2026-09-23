//
//  PaletteItemAssembler.swift
//  Vakta
//
//  Flattens the palette's three sources -- open sessions, each session's
//  already-known workspaces, and the static command rows -- into one
//  ordered `[PaletteItem]`. Pure: takes plain snapshots, no store access.
import Foundation

enum PaletteItemAssembler {
    struct SessionEntry: Equatable {
        let id: UUID
        let title: String
        let status: AgentStatus
    }

    struct GlobalPaneEntry: Equatable {
        let pane: Pane
        let sessionID: UUID
        let sessionTitle: String
        let workspaceID: String
        let workspaceTitle: String
    }

    /// - Parameters:
    ///   - sessions: display order for the session rows, and the order their
    ///     workspace rows follow (grouped per owning session).
    ///   - workspaces: a session's known workspaces, if any -- keyed by
    ///     session id, not the session's own multiplexer session name.
    ///   - workspaceStatus: a workspace's own agent status, keyed by
    ///     workspace id; missing entries fall back to `.none`.
    ///   - commands: the static command rows (already availability-filtered),
    ///     appended last.
    static func assemble(
        sessions: [SessionEntry],
        workspaces: [UUID: [Workspace]],
        workspaceStatus: [String: AgentStatus],
        commands: [AppCommand]
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []

        for session in sessions {
            items.append(PaletteItem(
                id: "session:\(session.id.uuidString)",
                title: session.title,
                subtitle: nil,
                category: .session,
                status: session.status,
                kind: .selectSession(session.id)
            ))
            for workspace in workspaces[session.id] ?? [] {
                items.append(PaletteItem(
                    id: "workspace:\(session.id.uuidString):\(workspace.id)",
                    title: workspace.label,
                    subtitle: session.title,
                    category: .workspace,
                    status: workspaceStatus[workspace.id] ?? .none,
                    kind: .focusWorkspace(sessionID: session.id, workspaceID: workspace.id)
                ))
            }
        }

        for command in commands {
            items.append(PaletteItem(
                id: "action:\(command.stableID)",
                title: command.title,
                subtitle: nil,
                category: .action,
                status: .none,
                kind: .command(command)
            ))
        }

        return items
    }

    static func assembleGlobalPanes(_ entries: [GlobalPaneEntry]) -> [PaletteItem] {
        entries.map { entry in
            PaletteItem(
                id: "global-pane:\(entry.sessionID.uuidString):\(entry.workspaceID):\(entry.pane.id)",
                title: entry.pane.label,
                subtitle: "\(entry.sessionTitle) / \(entry.workspaceTitle)",
                category: .pane,
                status: entry.pane.status,
                kind: .focusPane(
                    sessionID: entry.sessionID,
                    workspaceID: entry.workspaceID,
                    paneID: entry.pane.id
                )
            )
        }
    }

    static func assemble(
        panes: [Pane],
        sessionID: UUID,
        workspaceID: String
    ) -> [PaletteItem] {
        panes.map { pane in
            PaletteItem(
                id: "pane:\(sessionID.uuidString):\(workspaceID):\(pane.id)",
                title: pane.label,
                subtitle: pane.tabID,
                category: .pane,
                status: pane.status,
                kind: .focusPane(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    paneID: pane.id
                )
            )
        }
    }
}
