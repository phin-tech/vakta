//
//  GitHubPanelTests.swift
//  GitHubCoreTests

import XCTest
import VaktaExtensionKit
@testable import GitHubCore

final class GitHubPanelTests: XCTestCase {
    private let vakta = GitRemote(host: "github.com", owner: "phin-tech", name: "vakta")
    private let kata = GitRemote(host: "github.com", owner: "phin-tech", name: "kata")

    private func pr(_ number: Int, _ checks: [PullRequestCheck.State], draft: Bool = false, review: PullRequestReview? = nil, repo: GitRemote) -> PullRequest {
        PullRequest(number: number, title: "PR \(number)", url: "https://github.com/\(repo.owner)/\(repo.name)/pull/\(number)", isDraft: draft,
                    headBranch: "b\(number)", headOwner: "sam",
                    checks: checks.enumerated().map { PullRequestCheck(name: "c\($0.offset)", state: $0.element, url: nil) },
                    review: review, mergeState: .unknown)
    }

    private func placement(_ pr: PullRequest?, repo: GitRemote, branch: String) -> PullRequestPlacement {
        PullRequestPlacement(sessionKey: SessionKey(backend: "herdr", sessionName: "v"), sessionFocused: true,
                             pane: PaneContext(paneID: branch, workspace: nil, cwd: "/src/\(repo.name)", gitRoot: "/src/\(repo.name)", branch: branch, focused: false),
                             target: PullRequestTarget(repository: repo, branch: branch, headOwner: "sam"), pullRequest: pr)
    }

    func test_view_groupsByRepository_focusedFirst_onePRPerURL() {
        let view = GitHubPanel.view([
            placement(pr(3, [.passing], repo: kata), repo: kata, branch: "b3"),
            placement(pr(42, [.failing, .passing], repo: vakta), repo: vakta, branch: "b42"),
            placement(pr(42, [.failing, .passing], repo: vakta), repo: vakta, branch: "b42"),
            placement(nil, repo: vakta, branch: "main"),
        ], focusedRepository: "phin-tech/vakta")
        guard case .list(let list) = view else { return XCTFail() }
        XCTAssertEqual(list.sections.map(\.title), ["phin-tech/vakta", "phin-tech/kata"])
        XCTAssertEqual(list.sections.first?.items.map(\.title), ["#42 PR 42"])
        XCTAssertEqual(list.sections.first?.items.first?.subtitle, "checks failing · b42")
        XCTAssertEqual(list.sections.first?.items.first?.accessories.map(\.text), ["1/2"])
    }

    func test_detailButtons_dependOnState() {
        func callbacks(_ pr: PullRequest) -> [String] {
            GitHubActions.buttons(PullRequestRef(pr, target: PullRequestTarget(repository: vakta, branch: "b", headOwner: "sam"), cwd: "/r")).map(\.callback)
        }
        XCTAssertEqual(callbacks(pr(1, [.failing], repo: vakta)),
                       [GitHubCallbacks.openURL, GitHubActions.checkout, GitHubActions.rerun, GitHubActions.fix, GitHubActions.copy, GitHubActions.draft])
        XCTAssertEqual(callbacks(pr(2, [.passing], review: .changesRequested, repo: vakta)),
                       [GitHubCallbacks.openURL, GitHubActions.checkout, GitHubActions.fix, GitHubActions.copy, GitHubActions.draft])
        XCTAssertEqual(callbacks(pr(3, [.passing], draft: true, repo: vakta)),
                       [GitHubCallbacks.openURL, GitHubActions.checkout, GitHubActions.copy, GitHubActions.ready])
    }

    func test_commands_forTheFocusedPR() {
        let ref = PullRequestRef(pr(42, [.failing], repo: vakta), target: PullRequestTarget(repository: vakta, branch: "b42", headOwner: "sam"), cwd: "/r")
        let commands = GitHubActions.commands(ref)
        XCTAssertEqual(commands.map(\.title), [
            "Open PR #42", "Check Out PR #42", "Re-run Failed Checks on #42", "Fix PR #42 with Agent", "Copy Link to PR #42", "Convert PR #42 to Draft",
        ])
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
        XCTAssertEqual(GitHubActions.commands(nil), [])
    }

    func test_payloadRoundTrip_andRejectsFlagLikeValues() throws {
        let ref = PullRequestRef(pr(42, [.failing], repo: vakta), target: PullRequestTarget(repository: vakta, branch: "fix", headOwner: "sam"), cwd: "/r")
        let decoded = try XCTUnwrap(PullRequestRef.decode(ref.payload))
        XCTAssertEqual(decoded.number, 42)
        XCTAssertEqual(decoded.repository, "phin-tech/vakta")
        XCTAssertEqual(decoded.cwd, "/r")
        XCTAssertNil(PullRequestRef.decode(.object(["url": .string("u"), "number": .number(1), "repository": .string("--repo=x/y"), "branch": .string("b")])))
        XCTAssertNil(PullRequestRef.decode(.object(["url": .string("u"), "number": .number(1.5), "repository": .string("o/r"), "branch": .string("b")])))
    }

    func test_argvAndEffects() {
        XCTAssertEqual(GitHubActions.checkoutEffects(repository: "phin-tech/vakta", number: 42, cwd: "/r"),
                       [.openPane(cwd: "/r", command: ["gh", "pr", "checkout", "42", "--repo", "phin-tech/vakta"], title: "#42")])
        XCTAssertEqual(GitHubActions.readyArgv(repository: "o/r", number: 7, ready: true), ["gh", "pr", "ready", "7", "--repo", "o/r"])
        XCTAssertEqual(GitHubActions.readyArgv(repository: "o/r", number: 7, ready: false).last, "--undo")
        XCTAssertEqual(GitHubActions.rerunArgv(repository: "o/r", runID: 99), ["gh", "run", "rerun", "99", "--failed", "--repo", "o/r"])
        XCTAssertEqual(GitHubActions.runIDs(Data(#"[{"databaseId": 5}, {"databaseId": 6}]"#.utf8)), [5, 6])
        let prompt = GitHubActions.fixPrompt(number: 42, title: "Fix $(it)", repository: "o/r", branch: "b", state: .failing)
        XCTAssertEqual(GitHubActions.agentCommand(template: ["claude", "{prompt}"], prompt: prompt), ["claude", prompt])
        XCTAssertTrue(GitHubActions.fixPrompt(number: 1, title: "t", repository: "o/r", branch: "b", state: .changesRequested).contains("--comments"))
        XCTAssertEqual(GitHubConfig.decode(Data(#"{"agentCommand": ["codex", "{prompt}"]}"#.utf8)).agentCommand, ["codex", "{prompt}"])
        XCTAssertEqual(GitHubConfig.decode(nil), .default)
    }
}
