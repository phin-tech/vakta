//
//  StatusBarTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the status bar: its visibility preference
//  (decode, cycle), what it shows for the focused pane (branch, one PR
//  glyph, a count of other PRs needing attention), and when the docked bar
//  is present.

import XCTest
@testable import Vakta

final class StatusBarTests: XCTestCase {
    // MARK: visibility preference

    func test_preferences_defaultToAuto_andDecodeMissingOrUnknownAsAuto() throws {
        XCTAssertEqual(StatusBarPreferences().visibility, .auto)
        XCTAssertEqual(try JSONDecoder().decode(StatusBarPreferences.self, from: Data("{}".utf8)).visibility, .auto)
        XCTAssertEqual(try JSONDecoder().decode(StatusBarPreferences.self, from: Data(#"{"visibility":"sideways"}"#.utf8)).visibility, .auto)
    }

    func test_preferences_roundTripEveryVisibility() throws {
        for visibility in StatusBarVisibility.allCases {
            let data = try JSONEncoder().encode(StatusBarPreferences(visibility: visibility))
            XCTAssertEqual(try JSONDecoder().decode(StatusBarPreferences.self, from: data).visibility, visibility)
        }
    }

    func test_visibility_cyclesThroughEveryMode() {
        XCTAssertEqual(StatusBarVisibility.auto.next, .autoHide)
        XCTAssertEqual(StatusBarVisibility.autoHide.next, .show)
        XCTAssertEqual(StatusBarVisibility.show.next, .hide)
        XCTAssertEqual(StatusBarVisibility.hide.next, .auto)
    }

    // MARK: content

    private let repository = GitRemote(host: "github.com", owner: "o", name: "r")

    private func pr(
        _ number: Int = 12,
        checks: PullRequestChecks = PullRequestChecks(passing: 0, failing: 0, pending: 0),
        review: PullRequestReview? = nil,
        isDraft: Bool = false
    ) -> PullRequestStatus {
        PullRequestStatus(
            number: number,
            url: "https://github.com/o/r/pull/\(number)",
            title: "Title \(number)",
            isDraft: isDraft,
            headBranch: "feat/x",
            headOwner: "o",
            checks: checks,
            review: review
        )
    }

    private func focused(_ pullRequest: PullRequestStatus?) -> FocusedPullRequestState {
        FocusedPullRequestState(
            target: PullRequestTarget(repository: repository, branch: "feat/x", headOwner: "o"),
            pullRequest: pullRequest
        )
    }

    func test_content_nothingFocused_isEmpty() {
        let content = StatusBarPresentation.content(focused: nil, workspaceSummaries: [:])
        XCTAssertTrue(content.isEmpty)
    }

    func test_content_branchWithoutPullRequest() {
        let content = StatusBarPresentation.content(focused: focused(nil), workspaceSummaries: [:])

        XCTAssertEqual(content.branch, "feat/x")
        XCTAssertNil(content.pullRequest)
        XCTAssertFalse(content.isEmpty)
    }

    func test_content_pullRequestCarriesNumberURLTitleAndDraft() {
        let content = StatusBarPresentation.content(focused: focused(pr(12, isDraft: true)), workspaceSummaries: [:])

        XCTAssertEqual(content.pullRequest, StatusBarPullRequest(
            number: 12,
            url: "https://github.com/o/r/pull/12",
            title: "Title 12",
            isDraft: true,
            glyph: .noChecks
        ))
    }

    func test_content_checksAreOrderedFailingPendingPassingThenByName() {
        var withChecks = pr(checks: PullRequestChecks(passing: 2, failing: 1, pending: 1))
        withChecks.checkRuns = [
            PullRequestCheck(name: "zeta", state: .passing, url: nil),
            PullRequestCheck(name: "Lint", state: .pending, url: nil),
            PullRequestCheck(name: "alpha", state: .passing, url: nil),
            PullRequestCheck(name: "build", state: .failing, url: "https://ci/1"),
        ]

        let pullRequest = try? XCTUnwrap(StatusBarPresentation.content(focused: focused(withChecks), workspaceSummaries: [:]).pullRequest)

        XCTAssertEqual(pullRequest?.checks.map(\.name), ["build", "Lint", "alpha", "zeta"])
        XCTAssertEqual(pullRequest?.checksLabel, "2/4")
    }

    func test_checksLabel_hiddenWithoutChecks() {
        let pullRequest = StatusBarPresentation.content(focused: focused(pr()), workspaceSummaries: [:]).pullRequest
        XCTAssertNil(pullRequest?.checksLabel)
    }

    func test_glyph_worstOfChecksAndReview() {
        let failing = PullRequestChecks(passing: 1, failing: 1, pending: 0)
        let pending = PullRequestChecks(passing: 1, failing: 0, pending: 1)
        let passing = PullRequestChecks(passing: 2, failing: 0, pending: 0)

        XCTAssertEqual(StatusBarPresentation.glyph(for: pr(checks: failing, review: .approved)), .failing)
        XCTAssertEqual(StatusBarPresentation.glyph(for: pr(checks: pending, review: .changesRequested)), .changesRequested)
        XCTAssertEqual(StatusBarPresentation.glyph(for: pr(checks: pending)), .pending)
        XCTAssertEqual(StatusBarPresentation.glyph(for: pr(checks: passing)), .passing)
        XCTAssertEqual(StatusBarPresentation.glyph(for: pr(review: .approved)), .passing)
        XCTAssertEqual(StatusBarPresentation.glyph(for: pr(review: .reviewRequired)), .noChecks)
        XCTAssertEqual(StatusBarPresentation.glyph(for: pr()), .noChecks)
    }

    func test_attentionElsewhere_countsOtherPullRequestsNeedingAttention() {
        let summaries = [
            "w1": PullRequestSummary(pullRequestCount: 2, failingChecks: 1, changesRequested: 0, needingAttention: 1),
            "w2": PullRequestSummary(pullRequestCount: 3, failingChecks: 1, changesRequested: 1, needingAttention: 2),
        ]
        let failingFocused = pr(checks: PullRequestChecks(passing: 0, failing: 1, pending: 0))

        XCTAssertEqual(StatusBarPresentation.content(focused: focused(failingFocused), workspaceSummaries: summaries).attentionElsewhere, 2)
        XCTAssertEqual(StatusBarPresentation.content(focused: focused(pr()), workspaceSummaries: summaries).attentionElsewhere, 3)
        XCTAssertEqual(StatusBarPresentation.content(focused: nil, workspaceSummaries: summaries).attentionElsewhere, 3)
        XCTAssertEqual(StatusBarPresentation.content(focused: focused(failingFocused), workspaceSummaries: [:]).attentionElsewhere, 0)
    }

    func test_content_onlyAttentionElsewhere_isNotEmpty() {
        let summaries = ["w1": PullRequestSummary(pullRequestCount: 1, failingChecks: 1, changesRequested: 0, needingAttention: 1)]

        XCTAssertFalse(StatusBarPresentation.content(focused: nil, workspaceSummaries: summaries).isEmpty)
    }

    // MARK: docked presence

    func test_isDocked_perVisibility() {
        let empty = StatusBarPresentation.content(focused: nil, workspaceSummaries: [:])
        let branch = StatusBarPresentation.content(focused: focused(nil), workspaceSummaries: [:])

        XCTAssertTrue(StatusBarPresentation.isDocked(.show, content: empty))
        XCTAssertFalse(StatusBarPresentation.isDocked(.hide, content: branch))
        XCTAssertFalse(StatusBarPresentation.isDocked(.auto, content: empty))
        XCTAssertTrue(StatusBarPresentation.isDocked(.auto, content: branch))
        XCTAssertFalse(StatusBarPresentation.isDocked(.autoHide, content: branch), "auto-hide overlays; it never docks")
    }

    func test_lookupsNeeded_skippedOnlyWhenHidden() {
        XCTAssertFalse(StatusBarVisibility.hide.needsPullRequestStatus)
        for visibility in [StatusBarVisibility.show, .auto, .autoHide] {
            XCTAssertTrue(visibility.needsPullRequestStatus, "\(visibility)")
        }
    }

    // MARK: commands

    func test_statusBarCommands_haveTitlesStableIDsAndLeaderSequences() {
        XCTAssertEqual(AppCommand.cycleStatusBar.title, "Cycle Status Bar Visibility")
        XCTAssertEqual(AppCommand.cycleStatusBar.stableID, "cycleStatusBar")
        XCTAssertEqual(AppCommand.openPullRequest.title, "Open Pull Request")
        XCTAssertEqual(AppCommand.openPullRequest.stableID, "openPullRequest")

        XCTAssertEqual(AppCommand.showStatusBarBriefly.title, "Show Status Bar Briefly")
        XCTAssertEqual(AppCommand.showStatusBarBriefly.stableID, "showStatusBarBriefly")

        let paths = LeaderTree.defaultRoot.commandPaths()
        XCTAssertEqual(paths[.showStatusBarBriefly], [31, 11], "o b")
        XCTAssertEqual(paths[.cycleStatusBar], [31, 9], "o v")
        XCTAssertEqual(paths[.openPullRequest], [31, 15], "o r")
        for command in [AppCommand.showStatusBarBriefly, .cycleStatusBar, .openPullRequest] {
            XCTAssertTrue(AppCommandCatalog.paletteCommands.contains(command), "\(command)")
            XCTAssertTrue(AppCommandCatalog.bindableCommands.contains(command), "\(command)")
        }
    }
}
