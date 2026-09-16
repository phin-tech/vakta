//
//  UnreadAttentionPolicyTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `UnreadAttentionPolicy`.
//  Deliberately separate from `AttentionTransitionPolicy.decide`: that one
//  bakes the notifyOnAttention/notifyOnFinished/bounceDock preference
//  toggles into its early returns, but "unread" bookkeeping for the bell
//  popover must track regardless of whether banners are silenced -- a user
//  who disables banners may still want the in-app indicator.

import XCTest
@testable import Vakta

final class UnreadAttentionPolicyTests: XCTestCase {
    private func shouldMark(
        from: AgentStatus?,
        to: AgentStatus,
        isSelected: Bool = false,
        appActive: Bool = false
    ) -> Bool {
        UnreadAttentionPolicy.shouldMarkUnread(from: from, to: to, isSelected: isSelected, appActive: appActive)
    }

    func test_firstObservation_fromNil_isNotMarkedUnread() {
        XCTAssertFalse(shouldMark(from: nil, to: .attention))
    }

    func test_transitionIntoAttention_notFocused_isMarkedUnread() {
        XCTAssertTrue(shouldMark(from: .working, to: .attention, isSelected: false, appActive: true))
    }

    func test_transitionIntoAttention_selectedAndAppActive_isNotMarkedUnread() {
        XCTAssertFalse(shouldMark(from: .working, to: .attention, isSelected: true, appActive: true))
    }

    func test_transitionIntoAttention_selectedButAppInactive_isMarkedUnread() {
        // The user is looking at a different app (Cmd-Tabbed away) with this
        // session still selected -- they have not actually seen this
        // transition yet. Pins the wiring requirement that `select(_:)`
        // alone isn't enough to clear it; `applicationDidBecomeActive` must
        // also clear the currently-selected session's unread flag.
        XCTAssertTrue(shouldMark(from: .working, to: .attention, isSelected: true, appActive: false))
    }

    func test_transitionIntoAttention_notSelectedAndAppInactive_isMarkedUnread() {
        XCTAssertTrue(shouldMark(from: .idle, to: .attention, isSelected: false, appActive: false))
    }

    func test_repeatedAttention_fromAttentionToAttention_isNotMarkedUnread() {
        XCTAssertFalse(shouldMark(from: .attention, to: .attention, isSelected: false, appActive: true))
    }

    func test_transitionToWorking_isNotMarkedUnread() {
        XCTAssertFalse(shouldMark(from: .idle, to: .working, isSelected: false, appActive: true))
    }

    func test_transitionToIdle_isNotMarkedUnread() {
        XCTAssertFalse(shouldMark(from: .working, to: .idle, isSelected: false, appActive: true))
    }

    func test_transitionToUnavailable_isNotMarkedUnread() {
        XCTAssertFalse(shouldMark(from: .attention, to: .unavailable, isSelected: false, appActive: true))
    }
}
