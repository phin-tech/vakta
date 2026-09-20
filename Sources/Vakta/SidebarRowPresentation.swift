//
//  SidebarRowPresentation.swift
//  Vakta
//
//  Pure decisions about which sidebar rows get a highlight or a status mark,
//  kept separate from SwiftUI so they're table-driven testable. Shared by
//  both sidebar styles; how each level is drawn stays in `SidebarView`.

import Foundation

enum SidebarRowPresentation {
    enum WorkspaceHighlight: Equatable {
        case none
        /// Focused on its server, but under a session that isn't selected:
        /// a faint marker of where that session will land.
        case subtle
        /// The focused workspace of the selected session -- what's on screen.
        case prominent
    }

    /// Only the selected session's focused workspace may read as selected;
    /// otherwise an expanded sidebar shows several competing highlights.
    static func workspaceHighlight(workspaceFocused: Bool, sessionSelected: Bool) -> WorkspaceHighlight {
        guard workspaceFocused else { return .none }
        return sessionSelected ? .prominent : .subtle
    }

    enum LabelEmphasis: Equatable { case dim, normal, strong }

    /// How a workspace row draws its highlight, shared by both sidebar styles
    /// (the view maps these to colors and fonts). The selected session row
    /// already uses the terminal's selection color, so the workspace that is
    /// actually on screen is set apart by an accent fill, a leading marker,
    /// and a strong label -- not by a faint gray wash, which read as selected
    /// only to someone already looking for it.
    struct WorkspaceRowStyle: Equatable {
        let fillOpacity: Double
        let usesAccentFill: Bool
        let showsMarker: Bool
        let labelEmphasis: LabelEmphasis
    }

    static func workspaceRowStyle(_ highlight: WorkspaceHighlight) -> WorkspaceRowStyle {
        switch highlight {
        case .none:
            return WorkspaceRowStyle(fillOpacity: 0, usesAccentFill: false, showsMarker: false, labelEmphasis: .dim)
        case .subtle:
            return WorkspaceRowStyle(fillOpacity: 0.07, usesAccentFill: false, showsMarker: true, labelEmphasis: .normal)
        case .prominent:
            return WorkspaceRowStyle(fillOpacity: 0.24, usesAccentFill: true, showsMarker: true, labelEmphasis: .strong)
        }
    }

    /// Whether `status` says anything about an agent. A session or workspace
    /// without one draws no mark (its column stays reserved for alignment)
    /// rather than a gray dot that carries no information.
    static func showsStatusMark(_ status: AgentStatus) -> Bool {
        switch status {
        case .working, .attention, .done, .idle: return true
        case .none, .unavailable: return false
        }
    }
}
