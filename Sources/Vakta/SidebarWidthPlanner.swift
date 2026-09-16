//
//  SidebarWidthPlanner.swift
//  Vakta
//
//  Pure sidebar-divider-width decision, extracted from
//  `AppDelegate.applySidebarWidth`. `@Published`'s projected publisher
//  (`$collapseStyle`) fires via `willSet` -- a subscriber's closure runs
//  BEFORE the stored property is actually updated, so re-reading
//  `sidebarSettings.collapseStyle` synchronously inside that same emission
//  returns the OLD value, not the one just emitted. The previous sink
//  discarded the emitted value entirely and did exactly that re-read,
//  meaning a collapse-style change while already collapsed (Icons <->
//  Hidden) applied one step behind: nothing visibly happened until some
//  later, unrelated emission.

import Foundation

enum SidebarWidthPlanner {
    /// The divider position for the sidebar's collapsed/expanded state and
    /// collapse style. Expanded always uses `expandedWidth`, regardless of
    /// `style` -- a style change while expanded only takes effect on the
    /// next collapse (AC: "leaves the expanded width until the next
    /// collapse").
    static func width(
        collapsed: Bool,
        style: SidebarCollapseStyle,
        collapsedWidth: CGFloat,
        expandedWidth: CGFloat
    ) -> CGFloat {
        guard collapsed else { return expandedWidth }
        return style == .hidden ? 0 : collapsedWidth
    }
}
