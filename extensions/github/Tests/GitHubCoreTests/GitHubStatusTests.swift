//
//  GitHubStatusTests.swift
//  GitHubCoreTests

import XCTest
import VaktaExtensionKit
@testable import GitHubCore

final class GitHubStatusTests: XCTestCase {
    private let repo = GitRemote(host: "github.com", owner: "phin-tech", name: "vakta")
    private let vakta = SessionKey(backend: "herdr", sessionName: "vakta")
    private let other = SessionKey(backend: "herdr", sessionName: "other")

    private func pr(_ number: Int, _ checks: [PullRequestCheck.State], merge: PullRequestMergeState = .unknown) -> PullRequest {
        PullRequest(number: number, title: "PR \(number)", url: "https://github.com/phin-tech/vakta/pull/\(number)", isDraft: false,
                    headBranch: "b\(number)", headOwner: "sam",
                    checks: checks.enumerated().map { PullRequestCheck(name: "c\($0.offset)", state: $0.element, url: "https://ci/\($0.offset)") },
                    review: nil, mergeState: merge)
    }

    private func pane(_ id: String, branch: String?, workspace: String = "agents", focused: Bool) -> PaneContext {
        PaneContext(paneID: id, workspace: WorkspaceRef(id: workspace, label: workspace), cwd: "/r", gitRoot: "/r", branch: branch, focused: focused)
    }

    private func placement(_ session: SessionKey, _ pane: PaneContext, _ pr: PullRequest?, focusedSession: Bool) -> PullRequestPlacement {
        PullRequestPlacement(sessionKey: session, sessionFocused: focusedSession, pane: pane,
                             target: PullRequestTarget(repository: repo, branch: pane.branch ?? "", headOwner: "sam"), pullRequest: pr)
    }

    private func contexts(_ panes: [PaneContext], otherPanes: [PaneContext] = []) -> [ExtensionContext] {
        [ExtensionContext(sessionKey: vakta, cwd: "/r", gitRoot: "/r", branch: nil, workspace: nil, focused: true, panes: panes),
         ExtensionContext(sessionKey: other, cwd: "/r", gitRoot: "/r", branch: nil, workspace: nil, focused: false, panes: otherPanes)]
    }

    func test_focusedPR_branchGlyphNumberAndChecks_withoutTrailingWhenItsTheOnlyPR() throws {
        let focused = pane("p1", branch: "b42", focused: true)
        let failing = pr(42, [.passing, .failing, .passing])
        let item = try XCTUnwrap(GitHubStatus.statusItem(contexts: contexts([focused]), placements: [placement(vakta, focused, failing, focusedSession: true)]))
        XCTAssertEqual(item.placement, .leading)
        XCTAssertEqual(item.segments.map(\.text), ["b42", "#42", "2/3"])
        XCTAssertEqual(item.segments[1].symbol, "xmark.circle.fill")
        XCTAssertEqual(item.segments[1].tint, .failure)
        XCTAssertEqual(item.segments[1].url, failing.url)
        guard case .list(let checks)? = item.segments[2].popover else { return XCTFail("no checks popover") }
        XCTAssertEqual(checks.sections.first?.items.map(\.title), ["c1", "c0", "c2"], "failing first")
        XCTAssertEqual(checks.sections.first?.items.first?.buttons.first?.callback, GitHubCallbacks.openURL)
    }

    func test_trailingSummary_whenAnotherPRExists_groupedFocusedSessionFirst() throws {
        let focused = pane("p1", branch: "b42", focused: true)
        let elsewhere = pane("q1", branch: "b7", workspace: "infra", focused: true)
        let item = try XCTUnwrap(GitHubStatus.statusItem(
            contexts: contexts([focused], otherPanes: [elsewhere]),
            placements: [placement(other, elsewhere, pr(7, [.pending]), focusedSession: false),
                         placement(vakta, focused, pr(42, [.passing], merge: .ready), focusedSession: true)]
        ))
        let summary = try XCTUnwrap(item.segments.last)
        XCTAssertEqual(summary.text, "2 PRs")
        XCTAssertEqual(summary.placement, .trailing)
        XCTAssertEqual(summary.tint, .warning, "worst of all: pending")
        guard case .list(let list)? = summary.popover else { return XCTFail() }
        XCTAssertEqual(list.sections.map(\.title), ["vakta › agents", "other › infra"])
        XCTAssertEqual(list.sections.first?.items.first?.title, "#42 PR 42")
    }

    func test_noBranch_noPRs_isNoItem() {
        XCTAssertNil(GitHubStatus.statusItem(contexts: contexts([pane("p1", branch: nil, focused: true)]), placements: []))
    }

    func test_branchWithoutPR_showsJustTheBranch() throws {
        let item = try XCTUnwrap(GitHubStatus.statusItem(contexts: contexts([pane("p1", branch: "main", focused: true)]), placements: []))
        XCTAssertEqual(item.segments.map(\.text), ["main"])
    }

    func test_attention_marksOnlyTheTransitionedPR() throws {
        let focused = pane("p1", branch: "b42", focused: true)
        let failing = pr(42, [.failing])
        let item = try XCTUnwrap(GitHubStatus.statusItem(contexts: contexts([focused]),
            placements: [placement(vakta, focused, failing, focusedSession: true)], attention: [failing.url]))
        XCTAssertEqual(item.segments.map(\.attention), [false, true, false])
    }

    func test_transitions_intoSettledStates_neverOnFirstSight() {
        let failing = pr(42, [.failing]), ready = pr(7, [.passing], merge: .ready), pending = pr(9, [.pending])
        let changed = GitHubNotices.transitions(
            previous: [failing.url: .pending, ready.url: .passing, pending.url: .failing],
            current: [failing, ready, pending, pr(100, [.failing])]
        )
        XCTAssertEqual(changed.map(\.number), [42, 7], "back to pending isn't news; #100 is first sight")
        XCTAssertEqual(GitHubNotices.notice(for: failing, sessionKey: vakta),
                       NotifyParams(title: "Checks failing on #42", body: "PR 42", sessionKey: vakta))
    }
}
