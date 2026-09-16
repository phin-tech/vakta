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
//  query resets highlight; stale/removed selection ID rejected." Extended
//  for the command-palette generalization (slice 2): items now span
//  sessions/herdr workspaces/actions (`PaletteItem`), and async-fetched
//  items (a session's workspaces) can be appended into an already-open
//  palette, guarded against a stale generation by `PaletteAppendPlanner`.

import XCTest
@testable import Vakta

@MainActor
final class SessionSwitcherModelTests: XCTestCase {
    private func item(_ title: String, status: AgentStatus = .none) -> PaletteItem {
        PaletteItem(id: title, title: title, subtitle: nil, category: .session, status: status, kind: .selectSession(UUID()))
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

        var selected: PaletteItem?
        model.onSelect = { selected = $0 }
        model.commit()

        XCTAssertEqual(selected, items[1])
    }

    func test_commit_queryNarrowsToNoMatches_isANoOp() {
        // `highlighted` resets to 0 on every query change (see its `didSet`),
        // so `commit`'s `matches.indices.contains(highlighted)` guard is only
        // ever exercised by an empty match list, not a stale index -- this is
        // that case.
        let model = SessionSwitcherModel()
        model.reset(items: [item("alpha"), item("beta")])

        model.query = "zzz"

        var selected: PaletteItem?
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

    // MARK: Generation / async append (slice 2)

    func test_reset_returnsAnIncreasingGenerationEachCall() {
        let model = SessionSwitcherModel()

        let first = model.reset(items: [])
        let second = model.reset(items: [])

        XCTAssertNotEqual(first, second)
    }

    func test_append_currentGeneration_addsItemsToTheList() {
        let model = SessionSwitcherModel()
        let generation = model.reset(items: [item("alpha")])

        model.append([item("guildhall")], forGeneration: generation)

        XCTAssertEqual(model.matches.map(\.title), ["alpha", "guildhall"])
    }

    func test_append_staleGeneration_afterAReset_isANoOp() {
        let model = SessionSwitcherModel()
        let staleGeneration = model.reset(items: [item("alpha")])
        model.reset(items: [item("beta")]) // palette closed and reopened

        model.append([item("guildhall")], forGeneration: staleGeneration)

        XCTAssertEqual(model.matches.map(\.title), ["beta"])
    }

    func test_append_preservesTheCurrentQueryAndHighlight() {
        let model = SessionSwitcherModel()
        let generation = model.reset(items: [item("session-one"), item("session-two")])
        model.query = "session" // matches both existing items, not the appended one
        model.moveDown()
        XCTAssertEqual(model.highlighted, 1)

        model.append([item("guildhall")], forGeneration: generation)

        XCTAssertEqual(model.query, "session")
        XCTAssertEqual(model.highlighted, 1)
    }
}
