//
//  NextUnreadSessionPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `NextUnreadSessionPlanner.next`,
//  the cmux-style "jump to next unread" wraparound search -- same shape as
//  `SessionSwitcherModel.moveDown`'s wraparound, but over the unread subset
//  of the session order instead of the filtered match list.

import XCTest
@testable import Vakta

final class NextUnreadSessionPlannerTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    private var order: [UUID] { [a, b, c, d] }

    func test_noUnread_isNil() {
        XCTAssertNil(NextUnreadSessionPlanner.next(after: a, sessionOrder: order, unread: []))
    }

    func test_unreadSessionAfterCurrent_returnsIt() {
        XCTAssertEqual(NextUnreadSessionPlanner.next(after: a, sessionOrder: order, unread: [c]), c)
    }

    func test_unreadSessionBeforeCurrent_wrapsAround() {
        XCTAssertEqual(NextUnreadSessionPlanner.next(after: c, sessionOrder: order, unread: [a]), a)
    }

    func test_multipleUnread_returnsTheNearestAfterCurrent() {
        XCTAssertEqual(NextUnreadSessionPlanner.next(after: a, sessionOrder: order, unread: [c, d]), c)
    }

    func test_multipleUnread_wrapsToTheNearestAfterCurrentGoingThroughTheEnd() {
        // order = [a,b,c,d], current = c: scanning forward hits d (not
        // unread), wraps to a (unread) before reaching b.
        XCTAssertEqual(NextUnreadSessionPlanner.next(after: c, sessionOrder: order, unread: [a, b]), a)
    }

    func test_onlyCurrentItselfIsUnread_returnsNil() {
        // Shouldn't normally happen (selecting clears unread), but "next"
        // means "a different session" -- there is nowhere else to go.
        XCTAssertNil(NextUnreadSessionPlanner.next(after: a, sessionOrder: order, unread: [a]))
    }

    func test_currentSelectionNotInSessionOrder_fallsBackToFirstUnreadInOrder() {
        let stale = UUID()
        XCTAssertEqual(NextUnreadSessionPlanner.next(after: stale, sessionOrder: order, unread: [c, b]), b)
    }

    func test_noCurrentSelection_returnsFirstUnreadInOrder() {
        XCTAssertEqual(NextUnreadSessionPlanner.next(after: nil, sessionOrder: order, unread: [d, b]), b)
    }

    func test_emptySessionOrder_isNil() {
        XCTAssertNil(NextUnreadSessionPlanner.next(after: nil, sessionOrder: [], unread: []))
    }
}
