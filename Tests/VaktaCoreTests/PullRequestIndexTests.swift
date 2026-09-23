//
//  PullRequestIndexTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the per-repo PR index built from one
//  `gh pr list` call: decoding, branch matching, the check rollup (worst-of
//  semantics ported from roux's `summarize_checks`), and classifying the
//  helper's outcome. No process execution.

import XCTest
@testable import Vakta

final class PullRequestIndexTests: XCTestCase {
    /// Trimmed from a real `gh pr list --json …` response (gh 2.97.0): a
    /// CheckRun and a StatusContext row, and `reviewDecision` as `""`.
    private let realShape = #"""
    [{"headRefName":"feature/kanban","headRepositoryOwner":{"id":"O_kgDOEBnigQ","login":"phin-tech"},"isCrossRepository":false,"isDraft":false,"number":244,"reviewDecision":"","title":"Kanban cleanup","url":"https://github.com/phin-tech/roux/pull/244","statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","detailsUrl":"https://github.com/x","name":"changes","status":"COMPLETED","workflowName":"CI"},{"__typename":"StatusContext","context":"deploy","state":"PENDING","targetUrl":"https://example.test"}]},
     {"headRefName":"fix/login","headRepositoryOwner":{"id":"O_2","login":"phin-tech"},"isCrossRepository":false,"isDraft":true,"number":250,"reviewDecision":"CHANGES_REQUESTED","title":"Fix login","url":"https://github.com/phin-tech/roux/pull/250","statusCheckRollup":[]}]
    """#

    private func index(_ json: String, limit: Int = 100) throws -> PullRequestIndex {
        try XCTUnwrap(PullRequestIndex.parse(Data(json.utf8), limit: limit))
    }

    // MARK: decoding

    func test_parse_realShape_decodesEachPullRequest() throws {
        let index = try index(realShape)

        XCTAssertEqual(index.pullRequests.map(\.number), [244, 250])
        let first = try XCTUnwrap(index.pullRequests.first)
        XCTAssertEqual(first.url, "https://github.com/phin-tech/roux/pull/244")
        XCTAssertEqual(first.title, "Kanban cleanup")
        XCTAssertEqual(first.headBranch, "feature/kanban")
        XCTAssertEqual(first.headOwner, "phin-tech")
        XCTAssertFalse(first.isDraft)
        XCTAssertNil(first.review)
        XCTAssertEqual(first.checks, PullRequestChecks(passing: 1, failing: 0, pending: 1))
        XCTAssertEqual(first.checks.state, .pending)

        let second = index.pullRequests[1]
        XCTAssertTrue(second.isDraft)
        XCTAssertEqual(second.review, .changesRequested)
        XCTAssertEqual(second.checks.state, .none)
    }

    func test_parse_reviewDecision_mapsKnownValuesAndDropsEmptyOrUnknown() throws {
        func review(_ raw: String) throws -> PullRequestReview? {
            let json = #"[{"headRefName":"b","headRepositoryOwner":{"login":"o"},"number":1,"url":"u","reviewDecision":"\#(raw)"}]"#
            return try index(json).pullRequests.first?.review
        }

        XCTAssertEqual(try review("APPROVED"), .approved)
        XCTAssertEqual(try review("CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(try review("REVIEW_REQUIRED"), .reviewRequired)
        XCTAssertEqual(try review("approved"), .approved)
        XCTAssertNil(try review(""))
        XCTAssertNil(try review("SOMETHING_NEW"))
    }

    func test_parse_olderGhWithoutOptionalFields_stillParses() throws {
        let json = #"[{"headRefName":"b","headRepositoryOwner":{"login":"o"},"number":7,"url":"u"}]"#

        let pr = try XCTUnwrap(try index(json).pullRequests.first)
        XCTAssertEqual(pr.number, 7)
        XCTAssertEqual(pr.title, "")
        XCTAssertFalse(pr.isDraft)
        XCTAssertNil(pr.review)
        XCTAssertEqual(pr.checks.state, .none)
    }

    func test_parse_entryMissingRequiredField_isDroppedWithoutLosingOthers() throws {
        let json = #"[{"headRefName":"b","number":1,"url":"u"},{"headRefName":"c","headRepositoryOwner":{"login":"o"},"number":2,"url":"u2"}]"#

        XCTAssertEqual(try index(json).pullRequests.map(\.number), [2])
    }

    func test_parse_malformedOrNonArray_isNil() {
        XCTAssertNil(PullRequestIndex.parse(Data("not json".utf8), limit: 100))
        XCTAssertNil(PullRequestIndex.parse(Data(#"{"message":"error"}"#.utf8), limit: 100))
    }

    func test_parse_emptyArray_isEmptyAndComplete() throws {
        let index = try index("[]")
        XCTAssertEqual(index.pullRequests, [])
        XCTAssertTrue(index.isComplete)
    }

    func test_parse_resultCountReachingLimit_isIncomplete() throws {
        let json = #"[{"headRefName":"a","headRepositoryOwner":{"login":"o"},"number":1,"url":"u"},{"headRefName":"b","headRepositoryOwner":{"login":"o"},"number":2,"url":"u"}]"#

        XCTAssertFalse(try index(json, limit: 2).isComplete)
        XCTAssertTrue(try index(json, limit: 3).isComplete)
    }

    // MARK: check details (roux `check_details` fallbacks)

    func test_parse_checkDetails_nameURLAndStatePerRow() throws {
        let json = #"""
        [{"headRefName":"b","headRepositoryOwner":{"login":"o"},"number":1,"url":"u","statusCheckRollup":[
          {"name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://ci/1"},
          {"context":"deploy","state":"SUCCESS","targetUrl":"https://deploy/2"},
          {"workflowName":"Nightly","status":"IN_PROGRESS"},
          {"name":"  ","context":"","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":" "}
        ]}]
        """#

        let checks = try XCTUnwrap(try index(json).pullRequests.first).checkRuns
        XCTAssertEqual(checks, [
            PullRequestCheck(name: "build", state: .failing, url: "https://ci/1"),
            PullRequestCheck(name: "deploy", state: .passing, url: "https://deploy/2"),
            PullRequestCheck(name: "Nightly", state: .pending, url: nil),
            PullRequestCheck(name: "Unnamed check", state: .passing, url: nil),
        ])
    }

    func test_parse_noRollup_hasNoCheckRuns() throws {
        let json = #"[{"headRefName":"b","headRepositoryOwner":{"login":"o"},"number":1,"url":"u"}]"#
        XCTAssertEqual(try index(json).pullRequests.first?.checkRuns, [])
    }

    // MARK: matching

    func test_pullRequest_matchesBranchAndHeadOwner() throws {
        let index = try index(realShape)

        XCTAssertEqual(index.pullRequest(branch: "fix/login", headOwner: "phin-tech")?.number, 250)
        XCTAssertEqual(index.pullRequest(branch: "fix/login", headOwner: "Phin-Tech")?.number, 250)
        XCTAssertNil(index.pullRequest(branch: "main", headOwner: "phin-tech"))
    }

    func test_pullRequest_forkWithSameBranchName_doesNotMatch() throws {
        let json = #"[{"headRefName":"main","headRepositoryOwner":{"login":"stranger"},"isCrossRepository":true,"number":9,"url":"u"}]"#

        XCTAssertNil(try index(json).pullRequest(branch: "main", headOwner: "phin-tech"))
        XCTAssertEqual(try index(json).pullRequest(branch: "main", headOwner: "stranger")?.number, 9)
    }

    // MARK: checks rollup (roux `summarize_checks` semantics)

    private func run(_ conclusion: String?, status: String = "COMPLETED") -> PullRequestCheckRow {
        PullRequestCheckRow(status: status, conclusion: conclusion, state: nil)
    }

    private func context(_ state: String) -> PullRequestCheckRow {
        PullRequestCheckRow(status: nil, conclusion: nil, state: state)
    }

    func test_checks_emptyRollup_isNone() {
        let checks = PullRequestChecks.summarize([])
        XCTAssertEqual(checks.state, .none)
        XCTAssertEqual(checks.total, 0)
    }

    func test_checks_failingWinsOverPendingAndPassing() {
        let checks = PullRequestChecks.summarize([run("SUCCESS"), run("FAILURE"), run(nil, status: "IN_PROGRESS")])
        XCTAssertEqual(checks, PullRequestChecks(passing: 1, failing: 1, pending: 1))
        XCTAssertEqual(checks.state, .failing)
        XCTAssertEqual(checks.total, 3)
    }

    func test_checks_pendingWinsOverPassing() {
        XCTAssertEqual(PullRequestChecks.summarize([run("SUCCESS"), run(nil, status: "QUEUED")]).state, .pending)
    }

    func test_checks_neutralAndSkippedCountAsPassing() {
        let checks = PullRequestChecks.summarize([run("NEUTRAL"), run("SKIPPED")])
        XCTAssertEqual(checks.state, .passing)
        XCTAssertEqual(checks.passing, 2)
    }

    func test_checks_everyFailureConclusionFails() {
        for conclusion in ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"] {
            XCTAssertEqual(PullRequestChecks.summarize([run(conclusion)]).state, .failing, conclusion)
        }
    }

    func test_checks_unknownOrMissingConclusion_isPending() {
        XCTAssertEqual(PullRequestChecks.summarize([run("BRAND_NEW")]).state, .pending)
        XCTAssertEqual(PullRequestChecks.summarize([run(nil)]).state, .pending)
        XCTAssertEqual(PullRequestChecks.summarize([PullRequestCheckRow(status: nil, conclusion: nil, state: nil)]).state, .pending)
    }

    func test_checks_statusContextStateField() {
        let checks = PullRequestChecks.summarize([context("SUCCESS"), context("ERROR"), context("EXPECTED")])
        XCTAssertEqual(checks, PullRequestChecks(passing: 1, failing: 1, pending: 1))
        XCTAssertEqual(PullRequestChecks.summarize([context("FAILURE")]).state, .failing)
    }

    func test_checks_valuesAreCaseInsensitive() {
        XCTAssertEqual(PullRequestChecks.summarize([run("success", status: "completed")]).state, .passing)
        XCTAssertEqual(PullRequestChecks.summarize([context("failure")]).state, .failing)
    }

    // MARK: helper argv and outcome

    func test_arguments_listOpenPullRequestsForExplicitRepository() {
        XCTAssertEqual(
            PullRequestListQuery.arguments(repository: "phin-tech/vakta", limit: 100),
            [
                "gh", "pr", "list", "--repo", "phin-tech/vakta", "--state", "open", "--limit", "100",
                "--json", "number,url,title,isDraft,headRefName,headRepositoryOwner,statusCheckRollup,reviewDecision"
            ]
        )
    }

    func test_interpret_success_parsesIndex() {
        let raw = ProcessRawResult(exitCode: 0, stdout: Data(realShape.utf8))
        guard case .pullRequests(let index) = PullRequestListQuery.interpret(raw, limit: 100) else {
            return XCTFail("expected pull requests")
        }
        XCTAssertEqual(index.pullRequests.count, 2)
    }

    func test_interpret_classifiesFailures() {
        XCTAssertEqual(PullRequestListQuery.interpret(ProcessRawResult(launchFailed: true), limit: 100), .ghUnavailable)
        XCTAssertEqual(PullRequestListQuery.interpret(ProcessRawResult(exitCode: 127), limit: 100), .ghUnavailable)
        XCTAssertEqual(PullRequestListQuery.interpret(ProcessRawResult(exitCode: 4), limit: 100), .notAuthenticated)
        XCTAssertEqual(PullRequestListQuery.interpret(ProcessRawResult(exitCode: 1), limit: 100), .failed)
        XCTAssertEqual(PullRequestListQuery.interpret(ProcessRawResult(timedOut: true), limit: 100), .failed)
        XCTAssertEqual(PullRequestListQuery.interpret(ProcessRawResult(cancelled: true), limit: 100), .failed)
        XCTAssertEqual(PullRequestListQuery.interpret(ProcessRawResult(exitCode: 0, stdout: Data("<html>".utf8)), limit: 100), .malformed)
    }
}
