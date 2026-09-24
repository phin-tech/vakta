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
        let content = StatusBarPresentation.content(focused: nil)
        XCTAssertTrue(content.isEmpty)
    }

    func test_content_branchWithoutPullRequest() {
        let content = StatusBarPresentation.content(focused: focused(nil))

        XCTAssertEqual(content.branch, "feat/x")
        XCTAssertNil(content.pullRequest)
        XCTAssertFalse(content.isEmpty)
    }

    func test_content_pullRequestCarriesNumberURLTitleAndDraft() {
        let content = StatusBarPresentation.content(focused: focused(pr(12, isDraft: true)))

        XCTAssertEqual(content.pullRequest, StatusBarPullRequest(
            number: 12,
            url: "https://github.com/o/r/pull/12",
            title: "Title 12",
            isDraft: true,
            glyph: .noChecks,
            branch: "feat/x"
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

        let pullRequest = try? XCTUnwrap(StatusBarPresentation.content(focused: focused(withChecks)).pullRequest)

        XCTAssertEqual(pullRequest?.checks.map(\.name), ["build", "Lint", "alpha", "zeta"])
        XCTAssertEqual(pullRequest?.checksLabel, "2/4")
    }

    func test_checksLabel_hiddenWithoutChecks() {
        let pullRequest = StatusBarPresentation.content(focused: focused(pr())).pullRequest
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

    func test_glyph_readyToMergeOnlyWhenGitHubSaysMergeable() {
        let passing = PullRequestChecks(passing: 2, failing: 0, pending: 0)
        func glyph(_ state: PullRequestMergeState, checks: PullRequestChecks = passing, review: PullRequestReview? = .approved) -> StatusBarGlyph {
            var status = pr(checks: checks, review: review)
            status.mergeState = state
            return StatusBarPresentation.glyph(for: status)
        }

        XCTAssertEqual(glyph(.ready), .readyToMerge)
        XCTAssertEqual(glyph(.ready, checks: PullRequestChecks(passing: 0, failing: 0, pending: 0), review: nil), .readyToMerge)
        XCTAssertEqual(glyph(.blocked), .passing, "checks green, but not mergeable yet")
        XCTAssertEqual(glyph(.unknown), .passing)
        XCTAssertEqual(glyph(.ready, checks: PullRequestChecks(passing: 1, failing: 1, pending: 0)), .failing, "worse states still win")
    }

    // MARK: all-sessions list

    private let sessionA = UUID()
    private let sessionB = UUID()

    private func listPR(
        _ number: Int,
        branch: String,
        checks: PullRequestChecks = PullRequestChecks(passing: 1, failing: 0, pending: 0),
        review: PullRequestReview? = nil
    ) -> PullRequestStatus {
        PullRequestStatus(
            number: number, url: "https://github.com/o/r/pull/\(number)", title: "T\(number)", isDraft: false,
            headBranch: branch, headOwner: "o", checks: checks, review: review
        )
    }

    private func input(_ session: UUID, _ title: String, _ workspace: String, _ workspaceTitle: String?, _ pullRequests: [PullRequestStatus]) -> StatusBarWorkspaceInput {
        StatusBarWorkspaceInput(sessionID: session, sessionTitle: title, workspaceID: workspace, workspaceTitle: workspaceTitle, pullRequests: pullRequests)
    }

    func test_list_currentWorkspaceFirst_thenGivenOrder_worstFirstWithinGroups() {
        let failing = PullRequestChecks(passing: 1, failing: 1, pending: 0)
        let pending = PullRequestChecks(passing: 0, failing: 0, pending: 1)
        let inputs = [
            input(sessionA, "vakta", "w1", "main", [listPR(5, branch: "e"), listPR(3, branch: "c", checks: failing)]),
            input(sessionA, "vakta", "w2", nil, []),
            input(sessionB, "guildhall", "w9", "docs", [listPR(8, branch: "h", checks: pending), listPR(2, branch: "b", review: .changesRequested)]),
        ]

        let content = StatusBarPresentation.content(
            focused: nil,
            lists: inputs,
            currentGroup: StatusBarGroupKey(sessionID: sessionB, workspaceID: "w9")
        )

        XCTAssertEqual(content.pullRequestGroups.map(\.title), ["guildhall › docs", "vakta › main"])
        XCTAssertEqual(content.pullRequestGroups.map(\.isCurrent), [true, false])
        XCTAssertEqual(content.pullRequestGroups.map { $0.pullRequests.map(\.number) }, [[2, 8], [3, 5]])
        XCTAssertEqual(content.listGlyph, .failing)
        XCTAssertEqual(content.listLabel, "4 PRs")
        XCTAssertTrue(content.showsPullRequestList)
        XCTAssertEqual(content.pullRequestGroups.first?.pullRequests.first?.branch, "b")
    }

    func test_list_workspaceWithoutTitle_usesItsID() {
        let content = StatusBarPresentation.content(focused: nil, lists: [input(sessionA, "vakta", "w2C", nil, [listPR(1, branch: "a")])])
        XCTAssertEqual(content.pullRequestGroups.first?.title, "vakta › w2C")
    }

    func test_list_countsDistinctPullRequests_andHidesWhenOnlyTheFocusedOne() {
        let shared = listPR(12, branch: "feat/x")
        let onlyFocused = StatusBarPresentation.content(
            focused: focused(pr(12)),
            lists: [input(sessionA, "a", "w1", nil, [shared]), input(sessionB, "b", "w1", nil, [shared])]
        )
        XCTAssertFalse(onlyFocused.showsPullRequestList)
        XCTAssertEqual(onlyFocused.listLabel, "1 PR")

        let withOther = StatusBarPresentation.content(
            focused: focused(pr(12)),
            lists: [input(sessionA, "a", "w1", nil, [shared]), input(sessionB, "b", "w1", nil, [shared, listPR(4, branch: "d")])]
        )
        XCTAssertTrue(withOther.showsPullRequestList)
        XCTAssertEqual(withOther.listLabel, "2 PRs")

        XCTAssertFalse(StatusBarPresentation.content(focused: nil, lists: []).showsPullRequestList)
    }

    func test_attentionElsewhere_countsDistinctPullRequestsAcrossSessionsExceptTheFocused() {
        let failing = PullRequestChecks(passing: 0, failing: 1, pending: 0)
        let lists = [
            input(sessionA, "a", "w1", nil, [listPR(12, branch: "feat/x", checks: failing), listPR(3, branch: "c", checks: failing)]),
            input(sessionB, "b", "w1", nil, [listPR(3, branch: "c", checks: failing), listPR(4, branch: "d", review: .changesRequested), listPR(5, branch: "e")]),
        ]
        let failingFocused = pr(12, checks: failing)

        XCTAssertEqual(StatusBarPresentation.content(focused: focused(failingFocused), lists: lists).attentionElsewhere, 2)
        XCTAssertEqual(StatusBarPresentation.content(focused: nil, lists: lists).attentionElsewhere, 3)
        XCTAssertFalse(StatusBarPresentation.content(focused: nil, lists: lists).isEmpty)
    }

    // MARK: keyboard

    func test_listKeys_mapArrowsReturnAndEscape_ignoringModifiedKeys() {
        XCTAssertEqual(StatusBarListKey.action(keyCode: 126, hasModifiers: false), .up)
        XCTAssertEqual(StatusBarListKey.action(keyCode: 125, hasModifiers: false), .down)
        XCTAssertEqual(StatusBarListKey.action(keyCode: 36, hasModifiers: false), .open)
        XCTAssertEqual(StatusBarListKey.action(keyCode: 76, hasModifiers: false), .open, "keypad Enter")
        XCTAssertEqual(StatusBarListKey.action(keyCode: 53, hasModifiers: false), .close)
        XCTAssertNil(StatusBarListKey.action(keyCode: 0, hasModifiers: false))
        XCTAssertNil(StatusBarListKey.action(keyCode: 126, hasModifiers: true))
    }

    func test_selection_startsAtTheEdge_andClamps() {
        XCTAssertEqual(StatusBarListKey.moved(nil, by: 1, count: 3), 0)
        XCTAssertEqual(StatusBarListKey.moved(nil, by: -1, count: 3), 2)
        XCTAssertEqual(StatusBarListKey.moved(1, by: 1, count: 3), 2)
        XCTAssertEqual(StatusBarListKey.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(StatusBarListKey.moved(0, by: -1, count: 3), 0)
        XCTAssertNil(StatusBarListKey.moved(nil, by: 1, count: 0))
        XCTAssertEqual(StatusBarListKey.moved(5, by: 0, count: 3), 2, "clamped when the list shrank")
    }

    // MARK: docked presence

    func test_isDocked_perVisibility() {
        let empty = StatusBarPresentation.content(focused: nil)
        let branch = StatusBarPresentation.content(focused: focused(nil))

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

        XCTAssertEqual(AppCommand.showPullRequests.title, "Show Pull Requests")
        XCTAssertEqual(AppCommand.showPullRequests.stableID, "showPullRequests")
        XCTAssertEqual(LeaderTree.defaultRoot.commandPaths()[.showPullRequests], [31, 37], "o l")
        XCTAssertTrue(AppCommandCatalog.paletteCommands.contains(.showPullRequests))
        XCTAssertTrue(AppCommandCatalog.bindableCommands.contains(.showPullRequests))

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
