//
//  StatusBarBehavior.swift
//  Vakta
//
//  Pure timing decisions for the status bar: Auto-hide's Dock-style
//  reveal/hide/peek, Automatic mode's undock hysteresis (so moving focus
//  between a repository pane and a plain one doesn't resize the terminal
//  back and forth), and which content changes warrant a peek. Callers
//  supply time and schedule one timer at `nextDeadline`.
//

import Foundation

/// Where the pointer is, relative to the bar's hot zone (a thin strip at the
/// terminal's bottom edge) and the bar's own area.
enum StatusBarPointer: Equatable {
    case hotZone
    case bar
    case outside
}

struct StatusBarAutoHideState: Equatable {
    var isRevealed = false
    /// When the pointer entered the hot zone while hidden.
    var dwellStartedAt: Date?
    /// The pointer is in the hot zone, or over the revealed bar.
    var isPointerInside = false
    /// When a revealed bar the pointer has left may hide.
    var hideAt: Date?
    /// A peek keeps the bar revealed until this time.
    var peekUntil: Date?
}

enum StatusBarAutoHide {
    /// How long the pointer must rest in the hot zone -- passing through on
    /// the way to the terminal's bottom row doesn't reveal the bar.
    static let dwell: TimeInterval = 0.15
    static let hideDelay: TimeInterval = 0.6
    static let peekDuration: TimeInterval = 3
    /// How long "Show Status Bar Briefly" keeps the bar up.
    static let summonDuration: TimeInterval = 25

    static func pointerMoved(_ state: StatusBarAutoHideState, to pointer: StatusBarPointer, at date: Date) -> StatusBarAutoHideState {
        var next = state
        let inside = pointer == .hotZone || (pointer == .bar && state.isRevealed)
        next.isPointerInside = inside
        if inside {
            next.hideAt = nil
            if !state.isRevealed, state.dwellStartedAt == nil { next.dwellStartedAt = date }
        } else {
            next.dwellStartedAt = nil
            if state.isRevealed, state.hideAt == nil { next.hideAt = date.addingTimeInterval(hideDelay) }
        }
        return next
    }

    static func peek(_ state: StatusBarAutoHideState, at date: Date) -> StatusBarAutoHideState {
        var next = state
        next.isRevealed = true
        next.dwellStartedAt = nil
        next.peekUntil = date.addingTimeInterval(peekDuration)
        return next
    }

    /// "Show Status Bar Briefly": reveals the bar for `summonDuration`, or --
    /// pressed again while it is showing, however it got there -- dismisses
    /// it at once. Hover still holds a summoned bar up past its duration.
    static func toggleSummon(_ state: StatusBarAutoHideState, at date: Date) -> StatusBarAutoHideState {
        guard !state.isRevealed else { return StatusBarAutoHideState() }
        var next = peek(state, at: date)
        next.peekUntil = date.addingTimeInterval(summonDuration)
        next.isPointerInside = false
        return next
    }

    static func tick(_ state: StatusBarAutoHideState, at date: Date) -> StatusBarAutoHideState {
        var next = state
        // Compared against the same deadline `nextDeadline` reports, not a
        // recomputed interval: `date - started` can land just under `dwell`
        // in floating point, so the timer would fire and not reveal.
        if let started = state.dwellStartedAt, date >= started.addingTimeInterval(dwell) {
            next.isRevealed = true
            next.dwellStartedAt = nil
        }
        if next.isRevealed, !next.isPointerInside,
           (next.hideAt.map { $0 <= date } ?? true),
           (next.peekUntil.map { $0 <= date } ?? true) {
            next.isRevealed = false
            next.hideAt = nil
            next.peekUntil = nil
        }
        return next
    }

    /// When `tick` next has something to decide; nil when nothing is pending.
    static func nextDeadline(_ state: StatusBarAutoHideState) -> Date? {
        if let started = state.dwellStartedAt { return started.addingTimeInterval(dwell) }
        guard state.isRevealed, !state.isPointerInside else { return nil }
        return [state.hideAt, state.peekUntil].compactMap { $0 }.max()
    }
}

struct StatusBarDockState: Equatable {
    var isDocked = false
    /// While docked in Automatic mode: when the content last became empty.
    var emptySince: Date?
}

enum StatusBarDockPlanner {
    static let undockDelay: TimeInterval = 10

    /// Automatic mode docks at once but undocks only after the content has
    /// been continuously empty for `undockDelay`; every other mode applies
    /// `wantsDock` immediately.
    static func update(_ state: StatusBarDockState, wantsDock: Bool, visibility: StatusBarVisibility, at date: Date) -> StatusBarDockState {
        guard visibility == .auto else { return StatusBarDockState(isDocked: wantsDock, emptySince: nil) }
        if wantsDock { return StatusBarDockState(isDocked: true, emptySince: nil) }
        guard state.isDocked else { return StatusBarDockState(isDocked: false, emptySince: nil) }
        let since = state.emptySince ?? date
        if date >= since.addingTimeInterval(undockDelay) { return StatusBarDockState(isDocked: false, emptySince: nil) }
        return StatusBarDockState(isDocked: true, emptySince: since)
    }

    static func nextDeadline(_ state: StatusBarDockState) -> Date? {
        guard state.isDocked, let since = state.emptySince else { return nil }
        return since.addingTimeInterval(undockDelay)
    }
}

enum StatusBarPeekPolicy {
    /// Peek when the focused PR settles into a different state (not when it
    /// merely goes back to pending), or when more other PRs need attention.
    /// Never on first observation or when focus moves to another PR.
    static func shouldPeek(from previous: StatusBarContent?, to current: StatusBarContent) -> Bool {
        guard let previous else { return false }
        if current.attentionElsewhere > previous.attentionElsewhere { return true }
        guard let before = previous.pullRequest, let after = current.pullRequest, before.number == after.number else {
            return false
        }
        return after.glyph != before.glyph && after.glyph != .pending && after.glyph != .noChecks
    }
}
