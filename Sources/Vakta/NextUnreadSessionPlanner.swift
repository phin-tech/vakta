//
//  NextUnreadSessionPlanner.swift
//  Vakta
//
//  cmux-style "jump to next unread" wraparound search -- same shape as
//  `SessionSwitcherModel.moveDown`'s wraparound, but over the unread subset
//  of the session order instead of a filtered match list.

import Foundation

enum NextUnreadSessionPlanner {
    /// The next unread session after `currentSelection` in `sessionOrder`,
    /// wrapping around. `nil` when there's no unread session to go to --
    /// including when the only unread entry is `currentSelection` itself
    /// (shouldn't normally happen; selecting clears unread), since "next"
    /// means a different session. `currentSelection` missing from
    /// `sessionOrder` (stale/removed) or `nil` (nothing selected) falls
    /// back to the first unread session in order.
    static func next(after currentSelection: Session.ID?, sessionOrder: [Session.ID], unread: Set<Session.ID>) -> Session.ID? {
        guard !sessionOrder.isEmpty, !unread.isEmpty else { return nil }
        guard let currentSelection, let currentIndex = sessionOrder.firstIndex(of: currentSelection) else {
            return sessionOrder.first { unread.contains($0) }
        }
        let count = sessionOrder.count
        for offset in 1..<count {
            let candidate = sessionOrder[(currentIndex + offset) % count]
            if unread.contains(candidate) { return candidate }
        }
        return nil
    }
}
