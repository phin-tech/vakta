//
//  KataBadgesTests.swift
//  KataVaktaCoreTests

import XCTest
import VaktaExtensionKit
@testable import KataVaktaCore

final class KataBadgesTests: XCTestCase {
    private let vakta = SessionKey(backend: "herdr", sessionName: "vakta")
    private let open: Set<String> = ["3kav", "fcae", "q9t2"]

    func test_branchNamingAnOpenIssue_wins() {
        var map = KataSessionMap()
        map.record("q9t2", for: vakta)
        XCTAssertEqual(KataBadges.issueID(branch: "3kav-extensions", sessionKey: vakta, map: map, openIDs: open), "3kav")
        XCTAssertEqual(KataBadges.issueID(branch: "feature/fcae_protocol", sessionKey: vakta, map: map, openIDs: open), "fcae")
    }

    func test_fallsBackToTheIssueTheSessionStarted_whileItIsOpen() {
        var map = KataSessionMap()
        map.record("q9t2", for: vakta)
        XCTAssertEqual(KataBadges.issueID(branch: "main", sessionKey: vakta, map: map, openIDs: open), "q9t2")
        XCTAssertEqual(KataBadges.issueID(branch: nil, sessionKey: vakta, map: map, openIDs: open), "q9t2")
        XCTAssertNil(KataBadges.issueID(branch: "main", sessionKey: vakta, map: map, openIDs: ["3kav"]), "a closed issue drops off")
        XCTAssertNil(KataBadges.issueID(branch: "main", sessionKey: SessionKey(backend: "tmux", sessionName: "x"), map: map, openIDs: open))
    }

    func test_badge_showsTheIdWithTitleAsPopover() {
        let issue = KataIssue(shortID: "fcae", projectID: 5, title: "Protocol kit", status: "open", priority: 1, owner: "sam", labels: [], body: "Body", parent: nil)
        let badge = KataBadges.badge(for: issue, sessionKey: vakta)
        XCTAssertEqual(badge.sessionKey, vakta)
        XCTAssertEqual(badge.text, "fcae")
        XCTAssertEqual(badge.symbol, "circle.lefthalf.filled")
        XCTAssertEqual(badge.popover, .detail(DetailView(title: "fcae · Protocol kit", markdown: "Body", fields: [
            .init(label: "Priority", value: "P1"), .init(label: "Owner", value: "sam"),
        ], buttons: [])))
    }

    func test_changes_setsNewAndChanged_andClearsRemoved() throws {
        let other = SessionKey(backend: "tmux", sessionName: "other")
        let gone = SessionKey(backend: "tmux", sessionName: "gone")
        func badge(_ key: SessionKey, _ text: String) -> BadgeSetParams { BadgeSetParams(sessionKey: key, text: text, symbol: nil, popover: nil) }
        let messages = KataBadges.changes(
            from: [vakta: badge(vakta, "fcae"), other: badge(other, "3kav"), gone: badge(gone, "q9t2")],
            to: [vakta: badge(vakta, "fcae"), other: badge(other, "q9t2")]
        )
        let methods = messages.compactMap { message -> String? in
            if case let .notification(method, _) = message { return method }
            return nil
        }
        XCTAssertEqual(methods.sorted(), [ProtocolMethod.badgeClear, ProtocolMethod.badgeSet])
        XCTAssertTrue(messages.contains(.notification(method: ProtocolMethod.badgeClear, params: try ExtensionProtocolCodec.encode(BadgeClearParams(sessionKey: gone)))))
        XCTAssertTrue(messages.contains(.notification(method: ProtocolMethod.badgeSet, params: try ExtensionProtocolCodec.encode(badge(other, "q9t2")))))
    }
}
