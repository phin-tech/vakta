//
//  HerdrPaneRegistryTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrPaneRegistry.update`: whether a herdr
//  session's known agent pane-id set changed since the last `agent list`
//  poll, and if so, the new full set `HerdrEventStreamClient` should
//  reconnect and resubscribe with (see docs/herdr-events-plan.md's design
//  pivot -- this deliberately holds no per-pane status, only membership).

import XCTest
@testable import Vakta

final class HerdrPaneRegistryTests: XCTestCase {
    func test_identicalSets_isUnchanged() {
        let result = HerdrPaneRegistry.update(current: ["w1:p1", "w1:p2"], latest: ["w1:p1", "w1:p2"])

        XCTAssertEqual(result, .unchanged)
    }

    func test_paneAdded_reportsChangedWithTheNewFullSet() {
        let result = HerdrPaneRegistry.update(current: ["w1:p1"], latest: ["w1:p1", "w1:p2"])

        XCTAssertEqual(result, .changed(paneIDs: ["w1:p1", "w1:p2"]))
    }

    func test_paneRemoved_reportsChangedWithTheNewFullSet() {
        let result = HerdrPaneRegistry.update(current: ["w1:p1", "w1:p2"], latest: ["w1:p1"])

        XCTAssertEqual(result, .changed(paneIDs: ["w1:p1"]))
    }

    func test_emptyToNonEmpty_isChanged() {
        let result = HerdrPaneRegistry.update(current: [], latest: ["w1:p1"])

        XCTAssertEqual(result, .changed(paneIDs: ["w1:p1"]))
    }

    func test_nonEmptyToEmpty_isChanged() {
        let result = HerdrPaneRegistry.update(current: ["w1:p1"], latest: [])

        XCTAssertEqual(result, .changed(paneIDs: []))
    }

    func test_emptyToEmpty_isUnchanged() {
        let result = HerdrPaneRegistry.update(current: [], latest: [])

        XCTAssertEqual(result, .unchanged)
    }

    func test_sameMembersDifferentIdentityIdenticalSets_isUnchanged() {
        // Same pane ids, reordered -- Set equality already handles this, but
        // pin it since callers build these from array->Set conversions.
        let result = HerdrPaneRegistry.update(current: ["w1:p2", "w1:p1"], latest: ["w1:p1", "w1:p2"])

        XCTAssertEqual(result, .unchanged)
    }
}
