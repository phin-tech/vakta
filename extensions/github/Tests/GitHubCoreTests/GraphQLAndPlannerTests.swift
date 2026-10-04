//
//  GraphQLAndPlannerTests.swift
//  GitHubCoreTests

import XCTest
@testable import GitHubCore

final class GraphQLAndPlannerTests: XCTestCase {
    private let vakta = GitRemote(host: "github.com", owner: "phin-tech", name: "vakta")
    private let kata = GitRemote(host: "github.com", owner: "phin-tech", name: "kata")

    func test_query_aliasesRepositoriesAndBranches_withEscapedLiterals() {
        let query = PullRequestQuery(targets: [
            PullRequestTarget(repository: vakta, branch: "fix\"x", headOwner: "sam"),
            PullRequestTarget(repository: vakta, branch: "main", headOwner: "sam"),
            PullRequestTarget(repository: kata, branch: "feat", headOwner: "sam"),
            PullRequestTarget(repository: vakta, branch: "main", headOwner: "sam"),
        ])
        XCTAssertTrue(query.text.contains(#"r0: repository(owner: "phin-tech", name: "vakta") { b0: pullRequests(headRefName: "fix\"x", states: OPEN, first: 10)"#))
        XCTAssertTrue(query.text.contains(#"b1: pullRequests(headRefName: "main""#))
        XCTAssertTrue(query.text.contains(#"r1: repository(owner: "phin-tech", name: "kata")"#))
        XCTAssertTrue(query.text.contains("rateLimit { remaining resetAt }"))
        XCTAssertEqual(query.targets.count, 3, "duplicate targets are queried once")
        XCTAssertEqual(query.targets["r1.b0"]?.branch, "feat")
    }

    func test_parse_matchesByAlias_andHeadOwner() throws {
        let query = PullRequestQuery(targets: [
            PullRequestTarget(repository: vakta, branch: "fix", headOwner: "sam"),
            PullRequestTarget(repository: vakta, branch: "lonely", headOwner: "sam"),
        ])
        let body = #"""
            {"data": {"rateLimit": {"remaining": 4990, "resetAt": "2026-10-03T21:00:00Z"},
              "r0": {
                "b0": {"nodes": [
                  {"number": 7, "title": "Fork's fix", "url": "https://github.com/phin-tech/vakta/pull/7", "isDraft": false,
                   "headRefName": "fix", "headRepositoryOwner": {"login": "someone-else"}, "commits": {"nodes": []}},
                  {"number": 42, "title": "Fix login race", "url": "https://github.com/phin-tech/vakta/pull/42", "isDraft": true,
                   "headRefName": "fix", "headRepositoryOwner": {"login": "Sam"}, "reviewDecision": "CHANGES_REQUESTED",
                   "mergeStateStatus": "BLOCKED",
                   "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": [
                     {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://ci/lint"},
                     {"__typename": "StatusContext", "context": "deploy", "state": "PENDING", "targetUrl": "https://ci/deploy"}
                   ]}}}}]}}
                ]},
                "b1": {"nodes": []}
              }}}
            """#
        let result = try PullRequestResponse.parse(Data(body.utf8), for: query).get()
        let fix = try XCTUnwrap(result.pullRequests[PullRequestTarget(repository: vakta, branch: "fix", headOwner: "sam")] ?? nil)
        XCTAssertEqual(fix.number, 42, "the fork's PR on a same-named branch is skipped")
        XCTAssertTrue(fix.isDraft)
        XCTAssertEqual(fix.review, .changesRequested)
        XCTAssertEqual(fix.mergeState, .blocked)
        XCTAssertEqual(fix.checks, [
            PullRequestCheck(name: "lint", state: .failing, url: "https://ci/lint"),
            PullRequestCheck(name: "deploy", state: .pending, url: "https://ci/deploy"),
        ])
        XCTAssertEqual(fix.state, .failing)
        let lonely = try XCTUnwrap(result.pullRequests[PullRequestTarget(repository: vakta, branch: "lonely", headOwner: "sam")])
        XCTAssertNil(lonely, "queried and confirmed to have no PR")
        XCTAssertEqual(result.rateRemaining, 4990)
        XCTAssertNotNil(result.rateResetsAt)
    }

    func test_parse_errors() {
        let query = PullRequestQuery(targets: [PullRequestTarget(repository: vakta, branch: "b", headOwner: "o")])
        XCTAssertEqual(PullRequestResponse.parse(Data(#"{"message": "Bad credentials"}"#.utf8), for: query).failure, .unauthorized)
        XCTAssertEqual(PullRequestResponse.parse(Data(#"{"errors": [{"type": "RATE_LIMITED", "message": "x"}]}"#.utf8), for: query).failure,
                       .rateLimited(resetsAt: nil))
        XCTAssertEqual(PullRequestResponse.parse(Data("nope".utf8), for: query).failure, .malformed)
        XCTAssertEqual(PullRequestResponse.parse(Data(#"{"errors": [{"message": "Could not resolve"}]}"#.utf8), for: query).failure,
                       .graphQL("Could not resolve"))
    }

    func test_due_tiers_forced_andRateLimit() {
        let now = Date(timeIntervalSince1970: 10_000)
        let last: [GitRemote: Date] = [vakta: now.addingTimeInterval(-20), kata: now.addingTimeInterval(-20)]
        let intervals = RefreshIntervals.default
        func due(focused: Set<GitRemote> = [], pending: Set<GitRemote> = [], forced: Set<GitRemote> = [], until: Date? = nil) -> Set<GitRemote> {
            RefreshPlanner.due(repositories: [vakta, kata], focused: focused, pending: pending, forced: forced,
                               lastFetched: last, now: now, intervals: intervals, rateLimitedUntil: until)
        }
        XCTAssertEqual(due(), [], "20 s is too soon for anyone")
        XCTAssertEqual(due(pending: [kata]), [kata], "pending checks: every 15 s")
        XCTAssertEqual(due(forced: [vakta]), [vakta])
        XCTAssertEqual(due(forced: [vakta], until: now.addingTimeInterval(60)), [], "nothing while rate limited")
        let fresh = RefreshPlanner.due(repositories: [vakta], focused: [], pending: [], forced: [], lastFetched: [:], now: now,
                                       intervals: intervals, rateLimitedUntil: nil)
        XCTAssertEqual(fresh, [vakta], "never fetched: due now")
    }

    func test_nextDue_andBackoff() {
        let now = Date(timeIntervalSince1970: 10_000)
        let next = RefreshPlanner.nextDue(repositories: [vakta, kata], focused: [vakta], pending: [],
                                          lastFetched: [vakta: now, kata: now], now: now, intervals: .default, rateLimitedUntil: nil)
        XCTAssertEqual(next, now.addingTimeInterval(30))
        let reset = now.addingTimeInterval(600)
        XCTAssertEqual(RefreshPlanner.rateLimitedUntil(remaining: 10, resetsAt: reset), reset)
        XCTAssertNil(RefreshPlanner.rateLimitedUntil(remaining: 4000, resetsAt: reset))
    }

    func test_intervals_config() {
        XCTAssertEqual(RefreshIntervals.decode(nil), .default)
        XCTAssertEqual(RefreshIntervals.decode(Data(#"{"refresh": {"focused": 1, "others": 600, "pending": 10}}"#.utf8)),
                       RefreshIntervals(focused: 5, others: 600, pending: 10), "floored at 5 s")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
