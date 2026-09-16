//
//  SessionLifecyclePlanner.swift
//  Vakta
//
//  Pure session selection/removal decisions, extracted from
//  `SessionStore.removeSession` so "closing selected/nonselected/last" and
//  "a repeated close callback for an already-gone session" are testable
//  without AppKit/Ghostty (`SessionStore` can't be constructed headlessly --
//  it owns a real `TerminalController`).

import Foundation

enum SessionRemovalPlanner {
    /// Whether `id` is still present and should actually be removed. A
    /// session's close callback can fire more than once for the same
    /// session (`terminalDidClose` racing a user-requested close, or
    /// libghostty reporting close twice) -- the second (and any further)
    /// call must be a no-op, not attempt to remove/reselect/save again.
    static func shouldRemove(_ id: Session.ID, from sessionIDs: [Session.ID]) -> Bool {
        sessionIDs.contains(id)
    }
}

enum SessionSelectionPlanner {
    /// The session that should be selected after removing `removedID` from
    /// `sessionIDsBeforeRemoval` (in on-screen order), given `previousSelection`.
    ///
    /// - Removing a session that wasn't selected never changes selection.
    /// - Removing the selected session falls back to whatever is now at the
    ///   same row index (so closing session 3 of 5 selects the new session
    ///   3, formerly session 4) -- clamped to the last remaining session if
    ///   the closed one was last.
    /// - Removing the last remaining session leaves nothing to select (`nil`).
    static func fallbackAfterRemoval(
        removedID: Session.ID,
        sessionIDsBeforeRemoval: [Session.ID],
        previousSelection: Session.ID?
    ) -> Session.ID? {
        guard previousSelection == removedID else { return previousSelection }
        guard let index = sessionIDsBeforeRemoval.firstIndex(of: removedID) else { return previousSelection }

        var remaining = sessionIDsBeforeRemoval
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return nil }

        let fallbackIndex = min(index, remaining.count - 1)
        return remaining[fallbackIndex]
    }
}
