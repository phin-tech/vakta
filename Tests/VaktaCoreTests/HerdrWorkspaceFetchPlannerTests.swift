//
//  HerdrWorkspaceFetchPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrWorkspaceFetchPlanner.shouldApply`: a
//  fetch-on-expand `herdr workspace list` query still completes
//  asynchronously, so a session closed while the query was in flight must
//  not have its (now-meaningless) result applied -- the single-session
//  analog of `AgentStatusApplyPlanner`/`DiscoveryApplyPlanner`'s
//  live-ID filtering.

import XCTest
@testable import Vakta

final class HerdrWorkspaceFetchPlannerTests: XCTestCase {
    func test_shouldApply_sessionStillLive_isTrue() {
        let id = Session.ID()
        XCTAssertTrue(HerdrWorkspaceFetchPlanner.shouldApply(sessionID: id, liveSessionIDs: [id]))
    }

    func test_shouldApply_sessionRemovedWhileFetchWasInFlight_isFalse() {
        let id = Session.ID()
        XCTAssertFalse(HerdrWorkspaceFetchPlanner.shouldApply(sessionID: id, liveSessionIDs: []))
    }

    func test_shouldApply_otherSessionsLive_thisOneRemoved_isFalse() {
        let id = Session.ID()
        let other = Session.ID()
        XCTAssertFalse(HerdrWorkspaceFetchPlanner.shouldApply(sessionID: id, liveSessionIDs: [other]))
    }
}
