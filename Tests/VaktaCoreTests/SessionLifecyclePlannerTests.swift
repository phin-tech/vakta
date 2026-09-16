//
//  SessionLifecyclePlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `SessionRemovalPlanner` and
//  `SessionSelectionPlanner`.

import XCTest
@testable import Vakta

final class SessionRemovalPlannerTests: XCTestCase {
    func test_shouldRemove_presentSession_isTrue() {
        let id = UUID()
        XCTAssertTrue(SessionRemovalPlanner.shouldRemove(id, from: [id, UUID()]))
    }

    func test_shouldRemove_alreadyGoneSession_isFalse_repeatedCloseCallbackIsANoOp() {
        let id = UUID()
        // Simulates a second close callback for a session already removed
        // by the first one -- must not attempt to remove/reselect/save again.
        XCTAssertFalse(SessionRemovalPlanner.shouldRemove(id, from: [UUID(), UUID()]))
    }

    func test_shouldRemove_emptySessionList_isFalse() {
        XCTAssertFalse(SessionRemovalPlanner.shouldRemove(UUID(), from: []))
    }
}

final class SessionSelectionPlannerTests: XCTestCase {
    private func fallback(
        removedID: UUID,
        ids: [UUID],
        previousSelection: UUID?
    ) -> UUID? {
        SessionSelectionPlanner.fallbackAfterRemoval(
            removedID: removedID,
            sessionIDsBeforeRemoval: ids,
            previousSelection: previousSelection
        )
    }

    func test_closingNonselectedSession_leavesSelectionUnchanged() {
        let a = UUID(); let b = UUID(); let c = UUID()
        XCTAssertEqual(fallback(removedID: b, ids: [a, b, c], previousSelection: a), a)
    }

    func test_closingSelectedMiddleSession_selectsTheNewSessionAtTheSameIndex() {
        let a = UUID(); let b = UUID(); let c = UUID()
        // Closing b (index 1 of 3) -- the session now at index 1 (c) becomes
        // selected, not a (index 0).
        XCTAssertEqual(fallback(removedID: b, ids: [a, b, c], previousSelection: b), c)
    }

    func test_closingSelectedFirstSession_selectsTheNewFirstSession() {
        let a = UUID(); let b = UUID(); let c = UUID()
        XCTAssertEqual(fallback(removedID: a, ids: [a, b, c], previousSelection: a), b)
    }

    func test_closingSelectedLastSession_clampsToTheNewLastSession() {
        let a = UUID(); let b = UUID(); let c = UUID()
        XCTAssertEqual(fallback(removedID: c, ids: [a, b, c], previousSelection: c), b)
    }

    func test_closingTheOnlySelectedSession_selectsNothing() {
        let a = UUID()
        XCTAssertNil(fallback(removedID: a, ids: [a], previousSelection: a))
    }

    func test_closingASessionWhileNothingWasSelected_selectsNothing() {
        let a = UUID(); let b = UUID()
        XCTAssertNil(fallback(removedID: a, ids: [a, b], previousSelection: nil))
    }

    func test_removedIDNotInList_leavesSelectionUnchanged() {
        // Defensive: shouldn't happen given `shouldRemove`'s guard upstream,
        // but the planner itself must not crash or misbehave if it does.
        let a = UUID(); let ghost = UUID()
        XCTAssertEqual(fallback(removedID: ghost, ids: [a], previousSelection: a), a)
    }
}
