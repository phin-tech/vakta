//
//  HerdrSocketDecoderTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrSocketDecoder.decode`, which turns one
//  newline-delimited JSON line from herdr's socket API into a minimal typed
//  `Frame`. Table-driven against the exact frame shapes captured in the
//  live spikes documented in docs/herdr-events-plan.md -- this client only
//  needs to know "an ack arrived" or "something pane-relevant happened",
//  never full response/event decoding (see the plan's design pivot).

import XCTest
@testable import Vakta

final class HerdrSocketDecoderTests: XCTestCase {
    func test_subscriptionStartedResponse_isSubscriptionAck() {
        let line = #"{"id":"sub_1","result":{"type":"subscription_started"}}"#

        XCTAssertEqual(HerdrSocketDecoder.decode(line: line), .subscriptionAck)
    }

    func test_paneAgentStatusChangedEvent_isPaneEventWithItsPaneID() {
        let line = #"{"data":{"agent":"claude","agent_status":"working","pane_id":"w2C:p1","workspace_id":"w2C"},"event":"pane.agent_status_changed"}"#

        XCTAssertEqual(HerdrSocketDecoder.decode(line: line), .paneEvent(paneID: "w2C:p1"))
    }

    func test_paneCreatedEvent_hasNoPaneIDFilterButIsStillAPaneEvent() {
        // pane.created/pane.closed/pane.agent_detected require only "type"
        // in herdr's schema -- session-wide, so the payload may omit pane_id
        // even though it happens to include one in practice.
        let line = #"{"data":{"pane_id":"w2C:p3","workspace_id":"w2C"},"event":"pane.created"}"#

        XCTAssertEqual(HerdrSocketDecoder.decode(line: line), .paneEvent(paneID: "w2C:p3"))
    }

    func test_paneClosedEventWithNoPaneIDField_isPaneEventWithNilPaneID() {
        let line = #"{"data":{"workspace_id":"w2C"},"event":"pane.closed"}"#

        XCTAssertEqual(HerdrSocketDecoder.decode(line: line), .paneEvent(paneID: nil))
    }

    func test_unrelatedEventType_isOther() {
        let line = #"{"data":{"workspace_id":"w2C"},"event":"workspace.renamed"}"#

        XCTAssertEqual(HerdrSocketDecoder.decode(line: line), .other)
    }

    func test_pingPongResponse_isOther() {
        let line = #"{"id":"req_1","result":{"type":"pong","version":"0.9.0","protocol":22}}"#

        XCTAssertEqual(HerdrSocketDecoder.decode(line: line), .other)
    }

    func test_errorResponse_isOther() {
        let line = #"{"id":"bad","error":{"code":"invalid_request","message":"missing field pane_id"}}"#

        XCTAssertEqual(HerdrSocketDecoder.decode(line: line), .other)
    }

    func test_invalidJSON_isMalformed() {
        XCTAssertEqual(HerdrSocketDecoder.decode(line: "{ not valid json"), .malformed)
    }

    func test_emptyLine_isMalformed() {
        XCTAssertEqual(HerdrSocketDecoder.decode(line: ""), .malformed)
    }

    func test_validJSONButNeitherResponseNorEventShape_isMalformed() {
        XCTAssertEqual(HerdrSocketDecoder.decode(line: #"{"unexpected":"shape"}"#), .malformed)
    }
}
