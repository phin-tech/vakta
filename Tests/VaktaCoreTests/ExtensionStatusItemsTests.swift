//
//  ExtensionStatusItemsTests.swift
//  VaktaCoreTests
//
//  Status Items: link order, truncation, unknown Extensions dropped, and
//  their effect on the status bar's Automatic visibility.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class ExtensionStatusItemsTests: XCTestCase {
    func test_merge_followsLinkOrder_andDropsUnknownExtensions() {
        let items: [String: StatusSetParams] = [
            "todo": StatusSetParams(text: "2 due", symbol: nil, popover: nil),
            "kata": StatusSetParams(text: "3 ready", symbol: "checklist", popover: nil),
            "gone": StatusSetParams(text: "x", symbol: nil, popover: nil),
        ]
        XCTAssertEqual(ExtensionStatusItems.merge(items, order: ["kata", "notes", "todo"]), [
            StatusBarExtensionItem(extensionID: "kata", text: "3 ready", symbol: "checklist", popover: nil),
            StatusBarExtensionItem(extensionID: "todo", text: "2 due", symbol: nil, popover: nil),
        ])
    }

    func test_merge_trimsAndTruncatesText_andDropsEmptyItems() {
        let items: [String: StatusSetParams] = [
            "kata": StatusSetParams(text: "  a very long status item text indeed  ", symbol: nil, popover: nil),
            "blank": StatusSetParams(text: "   ", symbol: "circle", popover: nil),
        ]
        XCTAssertEqual(ExtensionStatusItems.merge(items, order: ["kata", "blank"]).map(\.text), ["a very long status …"])
    }

    func test_truncate() {
        XCTAssertEqual(ExtensionStatusItems.truncate("short", to: 8), "short")
        XCTAssertEqual(ExtensionStatusItems.truncate("exactly8", to: 8), "exactly8")
        XCTAssertEqual(ExtensionStatusItems.truncate("too long!", to: 8), "too lon…")
    }

    func test_extensionItems_countAsContent_forAutomaticVisibility() {
        var content = StatusBarContent(branch: nil, pullRequest: nil, attentionElsewhere: 0)
        XCTAssertTrue(content.isEmpty)
        XCTAssertFalse(StatusBarPresentation.isDocked(.auto, content: content))

        content.extensionItems = [StatusBarExtensionItem(extensionID: "kata", text: "3 ready", symbol: nil, popover: nil)]
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(StatusBarPresentation.isDocked(.auto, content: content))
        XCTAssertFalse(StatusBarPresentation.isDocked(.hide, content: content))
    }
}
