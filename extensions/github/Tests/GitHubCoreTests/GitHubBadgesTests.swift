//
//  GitHubBadgesTests.swift
//  GitHubCoreTests

import XCTest
import VaktaExtensionKit
@testable import GitHubCore

final class GitHubBadgesTests: XCTestCase {
    private let repo = GitRemote(host: "github.com", owner: "o", name: "r")
    private let vakta = SessionKey(backend: "herdr", sessionName: "vakta")
    private let other = SessionKey(backend: "herdr", sessionName: "other")

    private func pr(_ number: Int, _ state: PullRequestCheck.State) -> PullRequest {
        PullRequest(number: number, title: "PR \(number)", url: "https://github.com/o/r/pull/\(number)", isDraft: false, headBranch: "b\(number)",
                    headOwner: "sam", checks: [PullRequestCheck(name: "c", state: state, url: nil)], review: nil, mergeState: .unknown)
    }

    private func placement(_ session: SessionKey, pane: String, focused: Bool, _ pr: PullRequest?) -> PullRequestPlacement {
        PullRequestPlacement(sessionKey: session, sessionFocused: false,
                             pane: PaneContext(paneID: pane, workspace: nil, cwd: "/r", gitRoot: "/r", branch: "b", focused: focused),
                             target: PullRequestTarget(repository: repo, branch: "b", headOwner: "sam"), pullRequest: pr)
    }

    func test_badge_isTheFocusedPanesPR_elseTheWorst() {
        let badges = GitHubBadges.badges([
            placement(vakta, pane: "p1", focused: false, pr(1, .failing)),
            placement(vakta, pane: "p2", focused: true, pr(2, .passing)),
            placement(other, pane: "q1", focused: false, pr(3, .passing)),
            placement(other, pane: "q2", focused: false, pr(4, .pending)),
            placement(other, pane: "q3", focused: true, nil),
        ])
        XCTAssertEqual(badges[vakta]?.text, "#2", "the focused pane's PR wins")
        XCTAssertEqual(badges[other]?.text, "#4", "no focused PR: the worst (pending)")
        XCTAssertEqual(badges[other]?.tint, .warning)
        guard case .list(let list)? = badges[vakta]?.popover else { return XCTFail() }
        XCTAssertEqual(list.sections.first?.items.map(\.title), ["#1 PR 1", "#2 PR 2"])
    }

    func test_noPRs_noBadge() {
        XCTAssertTrue(GitHubBadges.badges([placement(vakta, pane: "p1", focused: true, nil)]).isEmpty)
    }

    func test_changes_setAndClear() {
        let badge = BadgeSetParams(sessionKey: vakta, text: "#1", symbol: nil, popover: nil)
        XCTAssertEqual(GitHubBadges.changes(from: [:], to: [vakta: badge]).count, 1)
        XCTAssertEqual(GitHubBadges.changes(from: [vakta: badge], to: [vakta: badge]).count, 0)
        guard case .notification(let method, _)? = GitHubBadges.changes(from: [vakta: badge], to: [:]).first else { return XCTFail() }
        XCTAssertEqual(method, ProtocolMethod.badgeClear)
    }
}
