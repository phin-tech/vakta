//
//  SessionSwitcherModelTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `SessionSwitcherModel`'s filter/navigation/commit
//  state machine -- the AppKit-free decision logic behind the ⌘K palette.
//  `SessionSwitcherPanelTests` (VaktaIntegrationTests) already covers the
//  real keyDown/marked-text routing into this model; these cases cover the
//  model's own state transitions directly, per testing.md's `560r`/`eers`
//  row: "Whitespace/case filtering; empty results; wraparound navigation;
//  query resets highlight; stale/removed selection ID rejected."

import XCTest
@testable import Vakta

@MainActor
final class SessionSwitcherModelTests: XCTestCase {
    private func item(_ title: String) -> SessionSwitcherItem {
        SessionSwitcherItem(id: UUID(), title: title, status: .none)
    }

    func test_matches_emptyQuery_showsAllItemsInOrder() {
        let model = SessionSwitcherModel()
        let items = [item("alpha"), item("beta")]
        model.reset(items: items)

        XCTAssertEqual(model.matches.map(\.title), ["alpha", "beta"])
    }

    func test_matches_caseInsensitiveSubstring() {
        let model = SessionSwitcherModel()
        model.reset(items: [item("Herdr Session"), item("tmux"), item("Other")])

        model.query = "herdr"

        XCTAssertEqual(model.matches.map(\.title), ["Herdr Session"])
    }

    func test_matches_whitespaceOnlyQuery_isTreatedAsEmpty_showsAllItems() {
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha"), item("beta")])

        model.query = "   "

        XCTAssertEqual(model.matches.count, 2)
    }

    func test_matches_noSubstringMatch_isEmpty() {
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha")])

        model.query = "zzz"

        XCTAssertTrue(model.matches.isEmpty)
    }

    func test_queryChange_resetsHighlightToZero() {
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha"), item("beta"), item("gamma")])
        model.moveDown()
        XCTAssertEqual(model.highlighted, 1)

        model.query = "a"

        XCTAssertEqual(model.highlighted, 0)
    }

    func test_moveDown_wrapsAroundPastTheLastMatch() {
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha"), item("beta")])
        model.moveDown()
        XCTAssertEqual(model.highlighted, 1)

        model.moveDown()

        XCTAssertEqual(model.highlighted, 0)
    }

    func test_moveUp_wrapsAroundBeforeTheFirstMatch() {
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha"), item("beta")])

        model.moveUp()

        XCTAssertEqual(model.highlighted, 1)
    }

    func test_moveDown_noMatches_isANoOp() {
        let model = SessionSwitcherModel()
        model.reset(items: [])

        model.moveDown()

        XCTAssertEqual(model.highlighted, 0)
    }

    func test_moveUp_noMatches_isANoOp() {
        let model = SessionSwitcherModel()
        model.reset(items: [])

        model.moveUp()

        XCTAssertEqual(model.highlighted, 0)
    }

    func test_commit_callsOnSelectWithTheHighlightedMatch() {
        let model = SessionSwitcherModel()
        let items = [item("alpha"), item("beta")]
        model.reset(items: items)
        model.moveDown()

        var selected: UUID?
        model.onSelect = { selected = $0 }
        model.commit()

        XCTAssertEqual(selected, items[1].id)
    }

    func test_commit_queryNarrowsToNoMatches_isANoOp() {
        // `highlighted` resets to 0 on every query change (see its `didSet`),
        // so `commit`'s `matches.indices.contains(highlighted)` guard is only
        // ever exercised by an empty match list, not a stale index -- this is
        // that case.
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha"), item("beta")])

        model.query = "zzz"

        var selected: UUID?
        model.onSelect = { selected = $0 }
        model.commit()

        XCTAssertNil(selected)
    }

    func test_cancel_callsOnCancel() {
        let model = SessionSwitcherModel()
        var cancelled = false
        model.onCancel = { cancelled = true }

        model.cancel()

        XCTAssertTrue(cancelled)
    }

    func test_reset_reseedsItemsAndClearsQueryAndHighlight() {
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha"), item("beta")])
        model.query = "a"
        model.moveDown()

        model.reset(items: [item("gamma")])

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.highlighted, 0)
        XCTAssertEqual(model.matches.map(\.title), ["gamma"])
    }
}
