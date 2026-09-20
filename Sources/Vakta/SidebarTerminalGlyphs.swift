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

    /// The leading focus marker on a workspace row: a heavy left bar for the
    /// workspace on screen, a hairline for one that is merely focused under an
    /// unselected session. A space (not empty) when unfocused, so the column
    /// keeps every label aligned.
    static func workspaceFocusMarker(_ highlight: SidebarRowPresentation.WorkspaceHighlight) -> String {
        switch highlight {
        case .prominent: return "▌"
        case .subtle: return "▏"
        case .none: return " "
        }
    }

    /// A tmux workspace's command-result mark. It stays a filled circle for
    /// both success and failure so color carries the result without changing
    /// row alignment; an unset option gets the muted placeholder.
    static func tmuxCommandStatus(_ exitCode: Int?) -> String {
        exitCode == nil ? "·" : "●"
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
