//
//  StatusBarViewModelTests.swift
//  VaktaIntegrationTests
//
//  The status bar's popover bookkeeping for Extension segments: Auto-hide
//  holds the bar while any popover is open (tracked per popover, so a late
//  close of one can't release the hold while another is open), pinning,
//  and the keyboard on a pinned list (Return runs the selected row).

import XCTest
import VaktaExtensionKit
@testable import Vakta

@MainActor
final class StatusBarViewModelTests: XCTestCase {
    private let checks = StatusBarPopover.extensionSegment(StatusSegmentKey(extensionID: "github", index: 2))
    private let pulls = StatusBarPopover.extensionSegment(StatusSegmentKey(extensionID: "github", index: 3))

    func test_holdsWhileAnyPopoverIsOpen() {
        let model = StatusBarViewModel()
        XCTAssertFalse(model.isAnyPopoverOpen)

        model.setPopover(checks, open: true)
        model.setPopover(pulls, open: true)
        model.setPopover(checks, open: false)
        XCTAssertTrue(model.isAnyPopoverOpen, "the other list is still open")

        model.setPopover(pulls, open: false)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }

    func test_repeatedCloseIsHarmless() {
        let model = StatusBarViewModel()
        model.setPopover(checks, open: false)
        model.setPopover(checks, open: true)
        model.setPopover(checks, open: true)
        model.setPopover(checks, open: false)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }

    // MARK: pinned list and keyboard

    /// A model showing one segment whose Popover lists `rows` across two
    /// sections; activations are recorded (an in-memory boundary).
    private func model(rows: [[String]]) -> (StatusBarViewModel, () -> [String]) {
        let model = StatusBarViewModel()
        var activated: [String] = []
        model.activateExtensionRow = { key, itemID in activated.append("\(key.extensionID)#\(key.index):\(itemID)") }
        let popover = ViewDocument.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: rows.enumerated().map { index, ids in
            ListSection(title: "g\(index)", items: ids.map { ListItem(id: $0, title: $0, subtitle: nil, symbol: nil, accessories: [], detail: nil, buttons: []) })
        }))
        model.content = StatusBarContent(extensionItems: ExtensionStatusItems.merge(["github": StatusSetParams(placement: .leading, segments: [
            StatusSegment(text: "b"), StatusSegment(text: "#1"), StatusSegment(text: "1/1"), StatusSegment(text: "3 PRs", popover: popover, placement: .trailing),
        ])], order: ["github"]))
        return (model, { activated })
    }

    func test_clickTogglesThePin_andPinningHolds() {
        let (model, _) = model(rows: [["a"]])
        model.togglePin(pulls)
        XCTAssertEqual(model.pinned, pulls)
        XCTAssertTrue(model.isAnyPopoverOpen)

        model.togglePin(pulls)
        XCTAssertNil(model.pinned)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }

    func test_arrowsMoveAcrossSections_andReturnRunsTheSelectedRowAndCloses() {
        let (model, activated) = model(rows: [["a", "b"], ["c"]])
        model.togglePin(pulls)

        for _ in 0..<4 { XCTAssertTrue(model.handle(.down)) }
        XCTAssertEqual(model.selection, 2, "clamped at the last row")
        XCTAssertTrue(model.handle(.up))
        XCTAssertTrue(model.handle(.open))

        XCTAssertEqual(activated(), ["github#3:b"])
        XCTAssertNil(model.pinned)
        XCTAssertNil(model.selection)
    }

    func test_returnWithoutASelection_closesAndRunsNothing() {
        let (model, activated) = model(rows: [["a"]])
        model.togglePin(pulls)
        XCTAssertTrue(model.handle(.open))
        XCTAssertEqual(activated(), [])
        XCTAssertNil(model.pinned)
    }

    func test_escapeClosesAnyOpenList_otherwiseKeysPassThrough() {
        let (model, _) = model(rows: [["a"]])
        XCTAssertFalse(model.handle(.close), "nothing open: Escape reaches the terminal")
        XCTAssertFalse(model.handle(.down))

        model.setPopover(pulls, open: true)  // hover-opened
        XCTAssertFalse(model.handle(.down), "arrows only drive a pinned list")
        let generation = model.closeGeneration
        XCTAssertTrue(model.handle(.close))
        XCTAssertGreaterThan(model.closeGeneration, generation, "hover-opened lists are told to close")

        model.togglePin(pulls)
        XCTAssertTrue(model.handle(.close))
        XCTAssertNil(model.pinned)
    }

    func test_onePinnedListAtATime() {
        let (model, _) = model(rows: [["a"]])
        model.togglePin(checks)
        model.pin(pulls)
        XCTAssertEqual(model.pinned, pulls)
        XCTAssertNil(model.selection)
    }
}
