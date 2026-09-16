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
    /// True whenever a session is (or becomes) `.attention` and the user
    /// hasn't looked at it: this deliberately includes the first observation
    /// (`from == nil`, e.g. reattaching a still-running session on launch
    /// that was already waiting) -- a session paused on a question before
    /// Vakta was even opened must still surface in the bell popover.
    /// `AttentionTransitionPolicy.decide` silences that same first
    /// observation, but for a different reason (avoiding a banner-spam
    /// burst on launch); that's a banner-noise concern, not a "does the
    /// user know this needs them" concern, so the two intentionally don't
    /// share this guard. Excludes a repeated `.attention -> .attention`
    /// observation (no new information) and any session already being
    /// looked at (`isSelected && appActive`).
    static func shouldMarkUnread(
        from: AgentStatus?,
        to: AgentStatus,
        isSelected: Bool,
        appActive: Bool
    ) -> Bool {
        guard to == .attention, from != .attention else { return false }
        return !(isSelected && appActive)
    }
}
