//
//  PaletteItemAssembler.swift
//  Vakta
//
//  Flattens the palette's three sources -- open sessions, each session's
//  already-known herdr workspaces, and the static action list -- into one
//  ordered `[PaletteItem]`. Pure: takes plain snapshots, no store access.
import Foundation

enum PaletteItemAssembler {
    struct SessionEntry: Equatable {
        let id: UUID
        let title: String
        let status: AgentStatus
    }

    /// - Parameters:
    ///   - sessions: display order for the session rows, and the order their
    ///     workspace rows follow (grouped per owning session).
    ///   - herdrWorkspaces: a session's known workspaces, if any -- keyed by
    ///     session id, not the session's own herdr session name.
    ///   - workspaceStatus: a workspace's own agent status, keyed by
    ///     workspace id; missing entries fall back to `.none`.
    ///   - actions: the static command list, appended last.
    static func assemble(
        sessions: [SessionEntry],
        herdrWorkspaces: [UUID: [HerdrWorkspace]],
        workspaceStatus: [String: AgentStatus],
        actions: [PaletteAction]
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
            for workspace in herdrWorkspaces[session.id] ?? [] {
                items.append(PaletteItem(
                    id: "workspace:\(session.id.uuidString):\(workspace.id)",
                    title: workspace.label,
                    subtitle: session.title,
                    category: .herdrWorkspace,
                    status: workspaceStatus[workspace.id] ?? .none,
                    kind: .focusHerdrWorkspace(sessionID: session.id, workspaceID: workspace.id)
                ))
            }
        }

        for action in actions {
            items.append(PaletteItem(
                id: "action:\(action.id)",
                title: action.title,
                subtitle: nil,
                category: .action,
                status: .none,
                kind: .action(id: action.id)
            ))
        }

        return items
    }
}
