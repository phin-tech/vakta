//
//  PaneFocusRequestTests.swift
//  VaktaCoreTests
//
//  RED coverage for exact Herdr pane focus. The request must target the pane
//  by stable pane ID rather than approximating focus with directional motion.

import XCTest
@testable import Vakta

final class PaneFocusRequestTests: XCTestCase {
    func test_focusLine_targetsExactPaneByID() throws {
        let line = HerdrPaneFocusRequest.line(requestID: "focus-1", paneID: "w2C:p7")
        let data = try XCTUnwrap(line.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, "focus-1")
        XCTAssertEqual(object["method"] as? String, "pane.focus")
        XCTAssertEqual(
            (object["params"] as? [String: Any])?["pane_id"] as? String,
            "w2C:p7"
        )
        XCTAssertTrue(line.hasSuffix("\n"))
    }
}
