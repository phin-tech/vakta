//
//  HerdrAgentStatusPanesTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrAgentStatus.panes(fromAgentListJSON:)`,
//  which widens the `agent list` decode with per-pane detail (workspace id,
//  a human label derived from cwd, and herdr's own `focused` flag) -- the
//  input per-pane unread tracking needs to distinguish "this Vakta session
//  is selected" from "this specific herdr workspace within it is the one
//  being looked at" (see docs -- one herdr session can host multiple
//  workspaces, e.g. "guildhall"/"vakta"/"data-platform" all sharing one
//  socket, discovered live: a workspace can be `.attention` while a
//  DIFFERENT workspace in the same Vakta session has focus).

import XCTest
@testable import Vakta

final class HerdrAgentStatusPanesTests: XCTestCase {
    func test_realAgentListShape_extractsPerPaneDetailIncludingFocused() {
        let json = """
        {"result":{"agents":[\
        {"agent":"claude","agent_status":"blocked","pane_id":"w2C:p1","workspace_id":"w2C","cwd":"/Users/sam/src/guildhall","focused":false},\
        {"agent":"claude","agent_status":"working","pane_id":"w2D:p2","workspace_id":"w2D","cwd":"/Users/sam/src/vakta","focused":true}\
        ]}}
        """

        let panes = HerdrAgentStatus.panes(fromAgentListJSON: json)

        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].paneID, "w2C:p1")
        XCTAssertEqual(panes[0].workspaceID, "w2C")
        XCTAssertEqual(panes[0].label, "guildhall")
        XCTAssertEqual(panes[0].status, .attention)
        XCTAssertFalse(panes[0].focused)

        XCTAssertEqual(panes[1].paneID, "w2D:p2")
        XCTAssertTrue(panes[1].focused)
        XCTAssertEqual(panes[1].status, .working)
    }

    func test_missingWorkspaceIDAndCwd_fallsBackLabelToPaneID() {
        let json = #"{"result":{"agents":[{"agent_status":"idle","pane_id":"w1:p1"}]}}"#

        let panes = HerdrAgentStatus.panes(fromAgentListJSON: json)

        XCTAssertEqual(panes.count, 1)
        XCTAssertNil(panes[0].workspaceID)
        XCTAssertEqual(panes[0].label, "w1:p1")
    }

    func test_missingFocusedField_defaultsToFalse() {
        let json = #"{"result":{"agents":[{"agent_status":"idle","pane_id":"w1:p1"}]}}"#

        XCTAssertFalse(HerdrAgentStatus.panes(fromAgentListJSON: json)[0].focused)
    }

    func test_agentWithNoPaneID_isExcluded() {
        let json = #"{"result":{"agents":[{"agent_status":"idle"}]}}"#

        XCTAssertTrue(HerdrAgentStatus.panes(fromAgentListJSON: json).isEmpty)
    }

    func test_emptyAgentsList_isEmpty() {
        XCTAssertTrue(HerdrAgentStatus.panes(fromAgentListJSON: #"{"result":{"agents":[]}}"#).isEmpty)
    }

    func test_errorPayload_isEmpty() {
        let json = #"{"id":"req_1","error":{"code":"not_found","message":"session not found"}}"#

        XCTAssertTrue(HerdrAgentStatus.panes(fromAgentListJSON: json).isEmpty)
    }

    func test_malformedJSON_isEmpty() {
        XCTAssertTrue(HerdrAgentStatus.panes(fromAgentListJSON: "not json").isEmpty)
    }
}
