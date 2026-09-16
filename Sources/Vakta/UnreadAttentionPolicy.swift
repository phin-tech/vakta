//
//  UnreadAttentionPolicy.swift
//  Vakta
//
//  Whether a session's agent-status transition should mark it "unread" for
//  the sidebar bell popover. Deliberately separate from
//  `AttentionTransitionPolicy.decide`: that policy bakes the
//  notifyOnAttention/notifyOnFinished/bounceDock preference toggles into
//  its own early returns (a silenced banner is still `.silent`), but
//  "unread" bookkeeping must track regardless of those toggles -- a user
//  who disables banners may still want the in-app indicator.

import Foundation

enum UnreadAttentionPolicy {
    /// True exactly when this is a fresh transition into `.attention` the
    /// user hasn't already seen: not the first observation (`from == nil`,
    /// e.g. reattaching a still-running session on launch), a genuine
    /// transition (not `.attention -> .attention`), and the session wasn't
    /// already the one being looked at (`isSelected && appActive`).
    static func shouldMarkUnread(
        from: AgentStatus?,
        to: AgentStatus,
        isSelected: Bool,
        appActive: Bool
    ) -> Bool {
        guard let from, from != .attention, to == .attention else { return false }
        return !(isSelected && appActive)
    }
}
