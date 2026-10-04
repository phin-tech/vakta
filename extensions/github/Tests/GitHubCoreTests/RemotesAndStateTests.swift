//
//  RemotesAndStateTests.swift
//  GitHubCoreTests

import XCTest
@testable import GitHubCore

final class RemotesAndStateTests: XCTestCase {
    func test_remoteURLForms() {
        for url in ["git@github.com:phin-tech/vakta.git", "https://github.com/phin-tech/vakta", "ssh://git@github.com:22/phin-tech/vakta.git"] {
            XCTAssertEqual(GitRemote(url: url), GitRemote(host: "github.com", owner: "phin-tech", name: "vakta"), url)
        }
        XCTAssertNil(GitRemote(url: "/local/path"))
        XCTAssertNil(GitRemote(url: "https://github.com/only-owner"))
        XCTAssertEqual(GitRemote(url: "git@ghe.example.com:team/app.git")?.slug, "ghe.example.com/team/app")
    }

    func test_target_followsPushPrecedence_andUpstream() {
        let config = [
            "remote.origin.url": "git@github.com:sam/vakta.git",
            "remote.upstream.url": "git@github.com:phin-tech/vakta.git",
            "remote.fork.url": "git@github.com:other/vakta.git",
        ]
        XCTAssertEqual(
            RepoConfig.target(config: config, branch: "fix", supportedHosts: ["github.com"]),
            PullRequestTarget(repository: GitRemote(host: "github.com", owner: "phin-tech", name: "vakta"), branch: "fix", headOwner: "sam")
        )
        var pushed = config
        pushed["branch.fix.pushremote"] = "fork"
        XCTAssertEqual(RepoConfig.target(config: pushed, branch: "fix", supportedHosts: ["github.com"])?.headOwner, "other")
        XCTAssertNil(RepoConfig.target(config: config, branch: "fix", supportedHosts: ["gitlab.com"]))
    }

    func test_parseGitConfig() {
        let data = Data("remote.origin.url\ngit@github.com:o/r.git\u{0}branch.main.remote\norigin\u{0}".utf8)
        XCTAssertEqual(RepoConfig.parse(data), ["remote.origin.url": "git@github.com:o/r.git", "branch.main.remote": "origin"])
    }

    private func pr(checks: [PullRequestCheck.State] = [], review: PullRequestReview? = nil, merge: PullRequestMergeState = .unknown) -> PullRequest {
        PullRequest(number: 1, title: "t", url: "u", isDraft: false, headBranch: "b", headOwner: "o",
                    checks: checks.enumerated().map { PullRequestCheck(name: "c\($0.offset)", state: $0.element, url: nil) },
                    review: review, mergeState: merge)
    }

    func test_state_isWorstFirst() {
        XCTAssertEqual(pr(checks: [.passing, .failing], review: .changesRequested).state, .failing)
        XCTAssertEqual(pr(checks: [.passing, .pending], review: .changesRequested).state, .changesRequested)
        XCTAssertEqual(pr(checks: [.passing, .pending]).state, .pending)
        XCTAssertEqual(pr(checks: [.passing], merge: .ready).state, .readyToMerge)
        XCTAssertEqual(pr(checks: [.passing]).state, .passing)
        XCTAssertEqual(pr(review: .approved).state, .passing)
        XCTAssertEqual(pr().state, .noChecks)
        XCTAssertLessThan(PullRequestState.failing, PullRequestState.readyToMerge)
    }

    func test_checkStates() {
        XCTAssertEqual(PullRequestCheck.state(status: "IN_PROGRESS", conclusion: nil, state: nil), .pending)
        XCTAssertEqual(PullRequestCheck.state(status: "COMPLETED", conclusion: "SKIPPED", state: nil), .passing)
        XCTAssertEqual(PullRequestCheck.state(status: "COMPLETED", conclusion: "TIMED_OUT", state: nil), .failing)
        XCTAssertEqual(PullRequestCheck.state(status: nil, conclusion: nil, state: "ERROR"), .failing)
        XCTAssertEqual(PullRequestCheck.state(status: nil, conclusion: nil, state: "PENDING"), .pending)
    }

    func test_orderedChecks_failingPendingPassing_thenByName() {
        let ordered = PullRequest(number: 1, title: "", url: "", isDraft: false, headBranch: "", headOwner: "", checks: [
            PullRequestCheck(name: "b", state: .passing, url: nil), PullRequestCheck(name: "z", state: .failing, url: nil),
            PullRequestCheck(name: "a", state: .passing, url: nil), PullRequestCheck(name: "m", state: .pending, url: nil),
        ], review: nil, mergeState: .unknown).orderedChecks
        XCTAssertEqual(ordered.map(\.name), ["z", "m", "a", "b"])
    }
}
