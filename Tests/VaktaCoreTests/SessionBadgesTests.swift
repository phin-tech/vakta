//
//  SessionBadgesTests.swift
//  VaktaCoreTests

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class SessionBadgesTests: XCTestCase {
    private let vakta = SessionKey(backend: "herdr", sessionName: "vakta")
    private let other = SessionKey(backend: "tmux", sessionName: "other")

    private func badge(_ text: String, symbol: String? = nil) -> BadgeSetParams {
        BadgeSetParams(sessionKey: SessionKey(backend: "", sessionName: ""), text: text, symbol: symbol, popover: nil)
    }

    func test_display_showsTheFirstLinkedExtensionsBadge_andCountsTheRest() throws {
        let badges: [String: [SessionKey: BadgeSetParams]] = [
            "gh": [vakta: badge("PR #3")],
            "kata": [vakta: badge("fcae", symbol: "circle.fill"), other: badge("7cq8")],
            "todo": [vakta: badge("2 due")],
        ]
        let display = try XCTUnwrap(SessionBadges.display(for: vakta, badges: badges, order: ["kata", "gh", "todo"]))
        XCTAssertEqual(display.shown, SessionBadge(extensionID: "kata", text: "fcae", fullText: "fcae", symbol: "circle.fill", popover: nil))
        XCTAssertEqual(display.hiddenCount, 2)
        XCTAssertEqual(display.all.map(\.extensionID), ["kata", "gh", "todo"])
    }

    func test_display_singleBadge_hasNoOverflow() throws {
        let display = try XCTUnwrap(SessionBadges.display(for: other, badges: ["kata": [other: badge("7cq8")]], order: ["kata"]))
        XCTAssertEqual(display.hiddenCount, 0)
    }

    func test_display_truncatesText_butKeepsTheFullTextForTheTooltip() throws {
        let display = try XCTUnwrap(SessionBadges.display(for: vakta, badges: ["kata": [vakta: badge("  a-long-badge  ")]], order: ["kata"]))
        XCTAssertEqual(display.shown.text, "a-long-…")
        XCTAssertEqual(display.shown.fullText, "a-long-badge")
    }

    func test_display_ignoresUnknownSessions_unlinkedExtensions_andBlankText() {
        XCTAssertNil(SessionBadges.display(for: vakta, badges: ["kata": [other: badge("7cq8")]], order: ["kata"]))
        XCTAssertNil(SessionBadges.display(for: vakta, badges: ["gone": [vakta: badge("x")]], order: ["kata"]))
        XCTAssertNil(SessionBadges.display(for: vakta, badges: ["kata": [vakta: badge("   ")]], order: ["kata"]))
    }
}
