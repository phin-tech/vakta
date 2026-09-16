//
//  HerdrAgentStatusPaneIDsTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrAgentStatus.paneIDs(fromAgentListJSON:)`,
//  which widens the existing `agent list` JSON decode (previously only
//  `agent_status`) to also expose each agent's `pane_id` -- the input
//  `HerdrPaneRegistry` needs to detect pane membership changes. Fixture JSON
//  is the exact real shape captured from a live `herdr agent list` call
//  (see docs/herdr-events-plan.md).

import XCTest
@testable import Vakta

final class HerdrAgentStatusPaneIDsTests: XCTestCase {
    func test_realAgentListShape_extractsEveryPaneID() {
        let json = """
        {"id":"cli:agent:list","result":{"agents":[\
        {"agent":"claude","agent_status":"idle","pane_id":"w2C:p1"},\
        {"agent":"claude","agent_status":"working","pane_id":"w2D:p2"}\
        ],"type":"agent_list"}}
        """

        XCTAssertEqual(HerdrAgentStatus.paneIDs(fromAgentListJSON: json), ["w2C:p1", "w2D:p2"])
    }

    func test_emptyAgentsList_isEmptySet() {
        let json = #"{"result":{"agents":[]}}"#

        XCTAssertEqual(HerdrAgentStatus.paneIDs(fromAgentListJSON: json), [])
    }

    func test_errorPayload_isEmptySet() {
        let json = #"{"id":"req_1","error":{"code":"not_found","message":"session not found"}}"#

        XCTAssertEqual(HerdrAgentStatus.paneIDs(fromAgentListJSON: json), [])
    }

    func test_malformedJSON_isEmptySet() {
        XCTAssertEqual(HerdrAgentStatus.paneIDs(fromAgentListJSON: "not json"), [])
    }
}
