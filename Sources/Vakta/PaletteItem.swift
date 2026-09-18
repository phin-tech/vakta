//
//  PaletteItem.swift
//  Vakta
//
//  One row in the ⌘K command palette -- a session to switch to, a
//  multiplexer workspace to focus, or an action to run. Flattened across
//  categories so a single query/highlight/commit state machine can treat
//  them uniformly; `category`/`subtitle`/`status` only affect how a row
//  renders.

import Foundation

enum PaletteCategory: Equatable {
    case session
    case workspace
    case action
}

enum PaletteItemKind: Equatable {
    case selectSession(UUID)
    case focusWorkspace(sessionID: UUID, workspaceID: String)
    case action(id: String)
}

struct PaletteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let category: PaletteCategory
    let status: AgentStatus
    let kind: PaletteItemKind
}

/// A static, always-available command (New Session, Toggle Sidebar, ...).
/// The shell resolves `id` to an actual handler; the core never executes
/// anything.
struct PaletteAction: Equatable {
    let id: String
    let title: String
}
