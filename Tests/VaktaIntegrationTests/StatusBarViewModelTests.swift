//
//  StatusBarViewModelTests.swift
//  VaktaIntegrationTests
//
//  The status bar's popover bookkeeping: Auto-hide holds the bar while any
//  popover (checks list, workspace list) is open, tracked per popover so a
//  late close of one can't release the hold while another is open.

import XCTest
@testable import Vakta

@MainActor
final class StatusBarViewModelTests: XCTestCase {
    func test_holdsWhileAnyPopoverIsOpen() {
        let model = StatusBarViewModel()
        XCTAssertFalse(model.isAnyPopoverOpen)

        model.setPopover(.checks, open: true)
        model.setPopover(.pullRequests, open: true)
        model.setPopover(.checks, open: false)
        XCTAssertTrue(model.isAnyPopoverOpen, "the workspace list is still open")

        model.setPopover(.pullRequests, open: false)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }

    func test_repeatedCloseIsHarmless() {
        let model = StatusBarViewModel()
        model.setPopover(.checks, open: false)
        model.setPopover(.checks, open: true)
        model.setPopover(.checks, open: true)
        model.setPopover(.checks, open: false)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }

    // MARK: pinned list and keyboard

    private func pullRequest(_ number: Int, checks: [PullRequestCheck] = []) -> StatusBarPullRequest {
        StatusBarPullRequest(
            number: number, url: "https://github.com/o/r/pull/\(number)", title: "T", isDraft: false,
            glyph: .passing, branch: "b", checks: checks
        )
    }

    /// A model whose URL opener is an in-memory fake recording what opened.
    private func model(groups: [[Int]]) -> (StatusBarViewModel, () -> [String]) {
        let model = StatusBarViewModel()
        var opened: [String] = []
        model.openURL = { opened.append($0) }
        model.content = StatusBarContent(
            branch: nil,
            pullRequest: nil,
            attentionElsewhere: 0,
            pullRequestGroups: groups.enumerated().map { index, numbers in
                StatusBarPullRequestGroup(title: "g\(index)", isCurrent: index == 0, pullRequests: numbers.map { pullRequest($0) })
            }
        )
        return (model, { opened })
    }

    func test_clickTogglesThePin_andPinningHolds() {
        let (model, _) = model(groups: [[1]])
        model.togglePin(.pullRequests)
        XCTAssertEqual(model.pinned, .pullRequests)
        XCTAssertTrue(model.isAnyPopoverOpen)

        model.togglePin(.pullRequests)
        XCTAssertNil(model.pinned)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }

    func test_arrowsMoveAcrossGroups_andReturnOpensTheSelectedRowAndCloses() {
        let (model, opened) = model(groups: [[1, 2], [3]])
        model.togglePin(.pullRequests)

        XCTAssertTrue(model.handle(.down))
        XCTAssertTrue(model.handle(.down))
        XCTAssertTrue(model.handle(.down))
        XCTAssertTrue(model.handle(.down))
        XCTAssertEqual(model.selection, 2, "clamped at the last row")
        XCTAssertTrue(model.handle(.up))
        XCTAssertTrue(model.handle(.open))

        XCTAssertEqual(opened(), ["https://github.com/o/r/pull/2"])
        XCTAssertNil(model.pinned)
        XCTAssertNil(model.selection)
    }

    func test_checksListRows_areItsChecksWithPages() {
        let model = StatusBarViewModel()
        var opened: [String] = []
        model.openURL = { opened.append($0) }
        model.content = StatusBarContent(
            branch: "b",
            pullRequest: pullRequest(1, checks: [
                PullRequestCheck(name: "build", state: .failing, url: "https://ci/1"),
                PullRequestCheck(name: "local", state: .passing, url: nil),
            ]),
            attentionElsewhere: 0
        )
        model.togglePin(.checks)

        XCTAssertTrue(model.handle(.down))
        XCTAssertTrue(model.handle(.down))
        XCTAssertTrue(model.handle(.open), "a row without a page is consumed but opens nothing")
        XCTAssertEqual(opened, [])
        XCTAssertNil(model.pinned)
    }

    func test_escapeClosesAnyOpenList_otherwiseKeysPassThrough() {
        let (model, _) = model(groups: [[1]])
        XCTAssertFalse(model.handle(.close), "nothing open: Escape reaches the terminal")
        XCTAssertFalse(model.handle(.down))

        model.setPopover(.pullRequests, open: true)  // hover-opened
        XCTAssertFalse(model.handle(.down), "arrows only drive a pinned list")
        let generation = model.closeGeneration
        XCTAssertTrue(model.handle(.close))
        XCTAssertGreaterThan(model.closeGeneration, generation, "hover-opened lists are told to close")

        model.togglePin(.pullRequests)
        XCTAssertTrue(model.handle(.close))
        XCTAssertNil(model.pinned)
    }

    func test_requestList_pinsThePullRequestList() {
        let (model, _) = model(groups: [[1]])
        model.togglePin(.checks)
        model.pin(.pullRequests)
        XCTAssertEqual(model.pinned, .pullRequests, "one pinned list at a time")
        XCTAssertNil(model.selection)
    }
}
