//
//  KataStatusTests.swift
//  KataVaktaCoreTests

import XCTest
import VaktaExtensionKit
@testable import KataVaktaCore

final class KataStatusTests: XCTestCase {
    private func issue(_ id: String, priority: Int = 2, owner: String? = nil) -> KataIssue {
        KataIssue(shortID: id, projectID: 5, title: "Title \(id)", status: "open", priority: priority, owner: owner, labels: [], body: nil, parent: nil)
    }

    func test_status_countsReadyUnownedIssues_withAStartingPopover() throws {
        let status = try XCTUnwrap(KataViews.status(
            open: [issue("rd02", priority: 2), issue("rd01", priority: 1), issue("mine", owner: "sam"), issue("bl01")],
            readyIDs: ["rd01", "rd02", "mine"]
        ))
        XCTAssertEqual(status.segments.first?.text, "2 ready")
        XCTAssertEqual(status.segments.first?.symbol, "checklist")
        guard case .list(let list)? = status.segments.first?.popover else { return XCTFail("no popover") }
        XCTAssertEqual(list.sections.map(\.title), ["Ready"])
        XCTAssertEqual(list.sections.first?.items.map(\.id), ["rd01", "rd02"])
        XCTAssertEqual(list.sections.first?.items.first?.buttons.first?.callback, KataStart.callback, "a row's first button starts it")
    }

    func test_status_singular_andNoneIsNil() {
        XCTAssertEqual(KataViews.status(open: [issue("rd01")], readyIDs: ["rd01"])?.segments.first?.text, "1 ready")
        XCTAssertNil(KataViews.status(open: [issue("bl01"), issue("mine", owner: "sam")], readyIDs: ["mine"]))
        XCTAssertNil(KataViews.status(open: [], readyIDs: []))
    }
}
