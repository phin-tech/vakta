//
//  ExtensionStatusItemsTests.swift
//  VaktaCoreTests
//
//  Status Items as segments: link order, placement, blank and excess
//  segments, truncation, safe URLs, attention transitions (peek), and
//  their effect on the status bar's Automatic visibility.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class ExtensionStatusItemsTests: XCTestCase {
    private func item(_ text: String, placement: StatusSetParams.Placement = .trailing) -> StatusSetParams {
        StatusSetParams(placement: placement, segments: [StatusSegment(text: text)])
    }

    func test_merge_followsLinkOrder_keepsPlacement_andDropsUnknownExtensions() {
        let items: [String: StatusSetParams] = [
            "todo": item("2 due"),
            "github": item("#42", placement: .leading),
            "gone": item("x"),
        ]
        let merged = ExtensionStatusItems.merge(items, order: ["github", "notes", "todo"])
        XCTAssertEqual(merged.map(\.extensionID), ["github", "todo"])
        XCTAssertEqual(merged.map(\.placement), [.leading, .trailing])
    }

    func test_merge_trimsTruncatesAndCapsSegments_andDropsBlankOnes() {
        let segments = ["  a very long status item text indeed  ", "   ", "b", "c", "d", "e"].map { StatusSegment(text: $0) }
        let merged = ExtensionStatusItems.merge(["x": StatusSetParams(placement: .trailing, segments: segments)], order: ["x"])
        XCTAssertEqual(merged.first?.segments.map(\.text), ["a very long status …", "b", "c", "d"])
        XCTAssertEqual(merged.first?.segments.map(\.index), [0, 1, 2, 3])
    }

    func test_merge_dropsAnItemWithOnlyBlankSegments() {
        XCTAssertEqual(ExtensionStatusItems.merge(["x": item("  ")], order: ["x"]), [])
    }

    func test_merge_keepsOnlyHTTPURLs() {
        let merged = ExtensionStatusItems.merge(["x": StatusSetParams(placement: .leading, segments: [
            StatusSegment(text: "ok", url: "https://github.com/o/r/pull/1"),
            StatusSegment(text: "bad", url: "file:///etc/passwd"),
        ])], order: ["x"])
        XCTAssertEqual(merged.first?.segments.map(\.url), [URL(string: "https://github.com/o/r/pull/1"), nil])
    }

    func test_truncate() {
        XCTAssertEqual(ExtensionStatusItems.truncate("short", to: 8), "short")
        XCTAssertEqual(ExtensionStatusItems.truncate("exactly8", to: 8), "exactly8")
        XCTAssertEqual(ExtensionStatusItems.truncate("too long!", to: 8), "too lon…")
    }

    func test_gainedAttention_onlyWhenASegmentTurnsAttentionOn() {
        func items(_ attention: Bool...) -> [StatusBarExtensionItem] {
            ExtensionStatusItems.merge(["gh": StatusSetParams(placement: .leading, segments: attention.enumerated().map {
                StatusSegment(text: "s\($0.offset)", attention: $0.element)
            })], order: ["gh"])
        }
        XCTAssertTrue(ExtensionStatusItems.gainedAttention(from: items(false, false), to: items(true, false)))
        XCTAssertFalse(ExtensionStatusItems.gainedAttention(from: items(true, false), to: items(true, false)), "already on")
        XCTAssertFalse(ExtensionStatusItems.gainedAttention(from: items(true), to: items(false)), "turning off doesn't peek")
        XCTAssertTrue(ExtensionStatusItems.gainedAttention(from: [], to: items(true)))
    }

    func test_extensionItems_countAsContent_forAutomaticVisibility() {
        var content = StatusBarContent(branch: nil, pullRequest: nil, attentionElsewhere: 0)
        XCTAssertTrue(content.isEmpty)
        content.extensionItems = ExtensionStatusItems.merge(["kata": item("3 ready")], order: ["kata"])
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(StatusBarPresentation.isDocked(.auto, content: content))
        XCTAssertFalse(StatusBarPresentation.isDocked(.hide, content: content))
    }

    func test_peekPolicy_peeksWhenAnExtensionSegmentGainsAttention() {
        var before = StatusBarContent(branch: "main", pullRequest: nil, attentionElsewhere: 0)
        before.extensionItems = ExtensionStatusItems.merge(["gh": StatusSetParams(placement: .leading, segments: [StatusSegment(text: "#1")])], order: ["gh"])
        var after = before
        after.extensionItems = ExtensionStatusItems.merge(["gh": StatusSetParams(placement: .leading, segments: [StatusSegment(text: "#1", attention: true)])], order: ["gh"])
        XCTAssertTrue(StatusBarPeekPolicy.shouldPeek(from: before, to: after))
        XCTAssertFalse(StatusBarPeekPolicy.shouldPeek(from: nil, to: after), "never on first observation")
    }
}
