//
//  PaletteMatcherTests.swift
//  VaktaCoreTests
//
//  RED, slice 1 of the ⌘K command palette generalization. Pure filtering,
//  matching `SessionSwitcherModel`'s existing title-match contract plus a
//  workspace row's subtitle (owning session/machine name).

import XCTest
@testable import Vakta

final class PaletteMatcherTests: XCTestCase {
    private func item(_ title: String, subtitle: String? = nil, category: PaletteCategory = .session) -> PaletteItem {
        PaletteItem(
            id: title,
            title: title,
            subtitle: subtitle,
            category: category,
            status: .none,
            kind: .action(id: title)
        )
    }

    func test_matches_emptyQuery_returnsAllItemsInOrder() {
        let items = [item("alpha"), item("beta")]

        XCTAssertEqual(PaletteMatcher.matches(query: "", in: items).map(\.title), ["alpha", "beta"])
    }

    func test_matches_whitespaceOnlyQuery_isTreatedAsEmpty() {
        let items = [item("alpha"), item("beta")]

        XCTAssertEqual(PaletteMatcher.matches(query: "   ", in: items).count, 2)
    }

    func test_matches_atLeader_searchesOnlyPaneRows_andStripsLeader() {
        let panes = [
            item("test-123", subtitle: "alpha / guildhall", category: .pane),
            item("test-999", subtitle: "beta / other", category: .pane),
            item("test-123", subtitle: nil, category: .session)
        ]

        XCTAssertEqual(
            PaletteMatcher.matches(query: "@test-123", in: panes).map(\.category),
            [.pane]
        )
    }

    func test_matches_doubleAt_escapesTheGlobalPaneLeader() {
        let items = [item("@test-123", category: .session), item("test-123", category: .pane)]

        XCTAssertEqual(
            PaletteMatcher.matches(query: "@@test", in: items).map(\.title),
            ["@test-123"]
        )
    }

    func test_matches_caseInsensitiveSubstring_onTitle() {
        let items = [item("Herdr Session"), item("tmux"), item("Other")]

        XCTAssertEqual(PaletteMatcher.matches(query: "herdr", in: items).map(\.title), ["Herdr Session"])
    }

    func test_matches_matchesSubtitle_evenWhenTitleDoesNot() {
        let items = [item("guildhall", subtitle: "vakta-3f9c", category: .workspace), item("data-platform", subtitle: "other-session", category: .workspace)]

        XCTAssertEqual(PaletteMatcher.matches(query: "3f9c", in: items).map(\.title), ["guildhall"])
    }

    func test_matches_noTitleOrSubtitleMatch_isEmpty() {
        let items = [item("alpha", subtitle: "beta")]

        XCTAssertTrue(PaletteMatcher.matches(query: "zzz", in: items).isEmpty)
    }

    func test_matches_itemWithNilSubtitle_doesNotCrashOnSubtitleSearch() {
        let items = [item("alpha", subtitle: nil)]

        XCTAssertTrue(PaletteMatcher.matches(query: "zzz", in: items).isEmpty)
    }
}
