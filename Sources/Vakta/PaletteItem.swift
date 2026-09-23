//
//  PaletteItem.swift
//  Vakta
//
//  One row in the ⌘K command palette -- a session to switch to, a
//  multiplexer workspace to focus, or an `AppCommand` to run. Flattened across
//  categories so a single query/highlight/commit state machine can treat
//  them uniformly; `category`/`subtitle`/`status` only affect how a row
//  renders.

import Foundation

enum PaletteCategory: Equatable {
    case session
    case workspace
    case pane
    case action
}

enum PaletteItemKind: Equatable {
    case selectSession(UUID)
    case focusWorkspace(sessionID: UUID, workspaceID: String)
    case focusPane(sessionID: UUID, workspaceID: String, paneID: String)
    case command(AppCommand)
}

enum PaletteNavigationScope: Equatable {
    case root
    case workspaces(sessionID: UUID)
    case panes(sessionID: UUID, workspaceID: String)
}

enum PaletteNavigationIntent: Equatable {
    case tab
    case shiftTab
    case enter
    case escape
}

enum PaletteNavigationOutcome: Equatable {
    case drillInto(PaletteNavigationScope)
    case commit(PaletteItemKind)
    case back
    case dismiss
    case noOp
}

/// Pure keyboard navigation decisions for the hierarchical command palette.
/// Enter always commits the highlighted row; Tab only drills into rows that
/// own a child scope.
enum PaletteNavigationPlanner {
    static func decide(
        intent: PaletteNavigationIntent,
        highlighted: PaletteItem,
        scope: PaletteNavigationScope
    ) -> PaletteNavigationOutcome {
        switch intent {
        case .enter:
            return .commit(highlighted.kind)
        case .tab:
            switch highlighted.kind {
            case .selectSession(let sessionID):
                return .drillInto(.workspaces(sessionID: sessionID))
            case .focusWorkspace(let sessionID, let workspaceID):
                return .drillInto(.panes(sessionID: sessionID, workspaceID: workspaceID))
            case .focusPane, .command:
                return .noOp
            }
        case .shiftTab, .escape:
            return scope == .root ? .dismiss : .back
        }
    }
}

struct PaletteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let category: PaletteCategory
    let status: AgentStatus
    let kind: PaletteItemKind
}
