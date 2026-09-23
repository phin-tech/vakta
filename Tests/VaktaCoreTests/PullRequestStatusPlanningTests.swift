//
//  PullRequestStatusPlanningTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the PR status store's decisions: which
//  repositories are due for a `gh` refresh, how an outcome updates the
//  cache, and how cached indexes project onto panes, the focused pane, and
//  per-workspace summaries.

import XCTest
@testable import Vakta

final class PullRequestStatusPlanningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let focused = GitRemote(host: "github.com", owner: "o", name: "focused")
    private let background = GitRemote(host: "github.com", owner: "o", name: "background")
    private let policy = PullRequestRefreshPolicy(focusedMaxAge: 60, backgroundMaxAge: 300)

    private func index(_ pullRequests: [PullRequestStatus]) -> PullRequestIndex {
        PullRequestIndex(pullRequests: pullRequests, isComplete: true)
    }

    private func pr(
        _ number: Int,
        branch: String,
        checks: PullRequestChecks = PullRequestChecks(passing: 1, failing: 0, pending: 0),
        review: PullRequestReview? = nil
    ) -> PullRequestStatus {
        PullRequestStatus(
            number: number,
            url: "https://github.com/o/r/pull/\(number)",
            title: "PR \(number)",
            isDraft: false,
            headBranch: branch,
            headOwner: "o",
            checks: checks,
            review: review
        )
    }

    private func fetched(_ secondsAgo: TimeInterval, failure: PullRequestListOutcome? = nil) -> PullRequestCacheEntry {
        PullRequestCacheEntry(index: index([]), fetchedAt: now.addingTimeInterval(-secondsAgo), lastFailure: failure)
    }

    private func due(
        _ cache: [GitRemote: PullRequestCacheEntry],
        forceFocused: Bool = false
    ) -> [GitRemote] {
        PullRequestRefreshPlanner.repositoriesToFetch(
            repositories: [focused, background],
            cache: cache,
            focused: focused,
            now: now,
            forceFocused: forceFocused,
            policy: policy
        )
    }

    // MARK: refresh planning

    func test_neverFetched_isDue() {
        XCTAssertEqual(due([:]), [focused, background])
    }

    func test_focusedRefreshesSoonerThanBackground() {
        XCTAssertEqual(due([focused: fetched(59), background: fetched(299)]), [])
        XCTAssertEqual(due([focused: fetched(60), background: fetched(120)]), [focused])
        XCTAssertEqual(due([focused: fetched(10), background: fetched(300)]), [background])
    }

    func test_forceFocused_refreshesOnlyTheFocusedRepository() {
        XCTAssertEqual(due([focused: fetched(1), background: fetched(1)], forceFocused: true), [focused])
    }

    func test_ghMissingOrUnauthenticated_backsOffToBackgroundAgeUnlessForced() {
        for failure in [PullRequestListOutcome.ghUnavailable, .notAuthenticated] {
            XCTAssertEqual(due([focused: fetched(120, failure: failure), background: fetched(1)]), [], "\(failure)")
            XCTAssertEqual(due([focused: fetched(300, failure: failure), background: fetched(1)]), [focused], "\(failure)")
            XCTAssertEqual(due([focused: fetched(1, failure: failure), background: fetched(1)], forceFocused: true), [focused], "\(failure)")
        }
    }

    func test_transientFailure_retriesOnTheNormalSchedule() {
        XCTAssertEqual(due([focused: fetched(60, failure: .failed), background: fetched(1)]), [focused])
    }

    // MARK: applying outcomes

    func test_success_replacesIndexAndClearsFailure() {
        let previous = PullRequestCacheEntry(index: index([pr(1, branch: "a")]), fetchedAt: now.addingTimeInterval(-99), lastFailure: .failed)
        let updated = index([pr(2, branch: "b")])

        XCTAssertEqual(
            PullRequestRefreshPlanner.applying(.pullRequests(updated), to: previous, at: now),
            PullRequestCacheEntry(index: updated, fetchedAt: now, lastFailure: nil)
        )
    }

    func test_failure_keepsPreviousIndexAndRecordsFailure() {
        let kept = index([pr(1, branch: "a")])
        let previous = PullRequestCacheEntry(index: kept, fetchedAt: now.addingTimeInterval(-99), lastFailure: nil)

        XCTAssertEqual(
            PullRequestRefreshPlanner.applying(.failed, to: previous, at: now),
            PullRequestCacheEntry(index: kept, fetchedAt: now, lastFailure: .failed)
        )
        XCTAssertEqual(
            PullRequestRefreshPlanner.applying(.notAuthenticated, to: nil, at: now),
            PullRequestCacheEntry(index: nil, fetchedAt: now, lastFailure: .notAuthenticated)
        )
    }

    func test_pruned_dropsRepositoriesNoPaneReferences() {
        let cache = [focused: fetched(1), background: fetched(1)]

        XCTAssertEqual(PullRequestRefreshPlanner.pruned(cache, liveRepositories: [focused]).keys.sorted { $0.name < $1.name }, [focused])
    }

    // MARK: projection

    private func target(_ repository: GitRemote, _ branch: String) -> PullRequestTarget {
        PullRequestTarget(repository: repository, branch: branch, headOwner: "o")
    }

    func test_statuses_joinPaneTargetsToCachedIndexes() {
        let cache = [
            focused: PullRequestCacheEntry(index: index([pr(1, branch: "a")]), fetchedAt: now, lastFailure: nil),
        ]
        let targets = [
            "p1": target(focused, "a"),
            "p2": target(focused, "no-pr"),
            "p3": target(background, "a"),
        ]

        XCTAssertEqual(PullRequestStatusProjection.statuses(targetsByPaneID: targets, cache: cache), ["p1": pr(1, branch: "a")])
    }

    func test_focusedState_isTheFocusedPanesTargetAndStatus() {
        let panes = [
            Pane(id: "p1", tabID: "t", label: "a", focused: false, status: .none, workspaceID: "w1", workingDirectory: "/a"),
            Pane(id: "p2", tabID: "t", label: "b", focused: true, status: .none, workspaceID: "w1", workingDirectory: "/b"),
        ]
        let targets = ["p1": target(focused, "a"), "p2": target(focused, "b")]
        let statuses = ["p2": pr(2, branch: "b")]

        XCTAssertEqual(
            PullRequestStatusProjection.focusedState(panes: panes, targetsByPaneID: targets, statuses: statuses),
            FocusedPullRequestState(target: target(focused, "b"), pullRequest: pr(2, branch: "b"))
        )
        XCTAssertNil(PullRequestStatusProjection.focusedState(panes: [panes[0]], targetsByPaneID: targets, statuses: statuses))
    }

    func test_focusedState_focusedPaneWithoutPullRequest_stillCarriesBranch() {
        let panes = [Pane(id: "p1", tabID: "t", label: "a", focused: true, status: .none, workspaceID: "w1", workingDirectory: "/a")]

        XCTAssertEqual(
            PullRequestStatusProjection.focusedState(panes: panes, targetsByPaneID: ["p1": target(focused, "a")], statuses: [:]),
            FocusedPullRequestState(target: target(focused, "a"), pullRequest: nil)
        )
    }

    func test_workspaceSummaries_countDistinctPullRequestsAndAttention() {
        let failing = PullRequestChecks(passing: 0, failing: 1, pending: 0)
        let panes = [
            Pane(id: "p1", tabID: "t", label: "", focused: false, status: .none, workspaceID: "w1", workingDirectory: "/a"),
            Pane(id: "p2", tabID: "t", label: "", focused: false, status: .none, workspaceID: "w1", workingDirectory: "/a"),
            Pane(id: "p3", tabID: "t", label: "", focused: false, status: .none, workspaceID: "w1", workingDirectory: "/b"),
            Pane(id: "p4", tabID: "t", label: "", focused: false, status: .none, workspaceID: "w2", workingDirectory: "/c"),
            Pane(id: "p5", tabID: "t", label: "", focused: false, status: .none, workspaceID: nil, workingDirectory: "/d"),
        ]
        let statuses = [
            "p1": pr(1, branch: "a", checks: failing),
            "p2": pr(1, branch: "a", checks: failing),
            "p3": pr(2, branch: "b", review: .changesRequested),
            "p4": pr(3, branch: "c"),
            "p5": pr(4, branch: "d", checks: failing),
        ]

        let summaries = PullRequestStatusProjection.workspaceSummaries(panes: panes, statuses: statuses)

        XCTAssertEqual(summaries, [
            "w1": PullRequestSummary(pullRequestCount: 2, failingChecks: 1, changesRequested: 1, needingAttention: 2),
            "w2": PullRequestSummary(pullRequestCount: 1, failingChecks: 0, changesRequested: 0, needingAttention: 0),
        ])
        XCTAssertTrue(summaries["w1"]?.needsAttention == true)
        XCTAssertTrue(summaries["w2"]?.needsAttention == false)
    }

    func test_workspaceSummaries_pullRequestFailingWithChangesRequested_needsAttentionOnce() {
        let panes = [Pane(id: "p1", tabID: "t", label: "", focused: false, status: .none, workspaceID: "w1", workingDirectory: "/a")]
        let both = pr(1, branch: "a", checks: PullRequestChecks(passing: 0, failing: 1, pending: 0), review: .changesRequested)

        XCTAssertEqual(
            PullRequestStatusProjection.workspaceSummaries(panes: panes, statuses: ["p1": both])["w1"],
            PullRequestSummary(pullRequestCount: 1, failingChecks: 1, changesRequested: 1, needingAttention: 1)
        )
    }
}
