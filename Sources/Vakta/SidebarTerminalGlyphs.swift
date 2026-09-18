//
//  SidebarTerminalGlyphs.swift
//  Vakta
//
//  Pure glyph decisions for the sidebar's terminal style, kept separate from
//  SwiftUI so they're table-driven testable. Terminal style draws text glyphs
//  in the terminal font instead of SF Symbols and `Circle()` shapes, so rows
//  sit on the font's character grid the way herdr's own sidebar does. Color
//  (see `sidebarStatusColor`), not shape, distinguishes the live statuses.

import Foundation

enum SidebarTerminalGlyphs {
    /// The tree-disclosure triangle beside a session that has workspaces.
    static func disclosure(expanded: Bool) -> String {
        expanded ? "▾" : "▸"
    }

    /// A workspace row's status column. Never blank, so labels stay aligned:
    /// a workspace with no known agent gets a muted middle dot.
    static func workspaceStatus(_ status: AgentStatus) -> String {
        switch status {
        case .working, .attention, .idle: return "○"
        case .done: return "✓"
        case .none, .unavailable: return "·"
        }
    }

    /// A session row's trailing status mark, or nil when the session has no
    /// agent to report on (a plain shell/tmux session).
    static func sessionStatus(_ status: AgentStatus) -> String? {
        switch status {
        case .working, .attention, .idle: return "●"
        case .done: return "✓"
        case .none, .unavailable: return nil
        }
    }
}
