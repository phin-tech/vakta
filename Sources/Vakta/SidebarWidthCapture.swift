//
//  SidebarWidthCapture.swift
//  Vakta
//
//  Pure decision for whether a divider position the user just dragged to
//  should be recorded as the sidebar's new *expanded* width. The split view
//  resizes both when the user drags AND when `applySidebarWidth` programmatically
//  collapses it (`setPosition`), so a capture taken while collapsed would save
//  the rail/hidden width as the "expanded" width -- the same class of bug the
//  `SidebarWidthPlanner` doc comment warns about. Rejecting collapsed, non-finite,
//  and sub-minimum observations (with no split-view delegate the user can drag
//  the divider to ~0, which is a collapse gesture, not a resize) keeps a
//  restored width sane; anything above the maximum is clamped.

import Foundation

enum SidebarWidthCapture {
    /// The width to persist for a just-observed divider `position`, or `nil`
    /// when the observation must be ignored.
    static func accepted(
        position: CGFloat,
        isCollapsed: Bool,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat? {
        guard !isCollapsed, position.isFinite, position >= minimum else { return nil }
        return min(position, maximum)
    }
}
