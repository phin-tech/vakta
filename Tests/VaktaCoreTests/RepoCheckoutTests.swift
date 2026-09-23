//
//  RepoCheckoutTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for turning pane working directories into PR lookup
//  keys: remote URL parsing, which remote is the head vs the PR's base,
//  deduplicating panes into keys, and when a directory needs (re)resolving.

import XCTest
@testable import Vakta

final class RepoCheckoutTests: XCTestCase {
    private let github: Set<String> = ["github.com"]

    // MARK: remote URLs

    func test_gitRemote_parsesCommonGitHubForms() {
        let expected = GitRemote(host: "github.com", owner: "phin-tech", name: "vakta")
        for url in [
            "git@github.com:phin-tech/vakta.git",
            "git@github.com:phin-tech/vakta",
            "ssh://git@github.com/phin-tech/vakta.git",
            "ssh://git@github.com:22/phin-tech/vakta.git",
            "https://github.com/phin-tech/vakta.git",
            "https://github.com/phin-tech/vakta",
            "https://github.com/phin-tech/vakta/",
            "https://sam@github.com/phin-tech/vakta.git",
            "git://github.com/phin-tech/vakta.git",
            "https://GitHub.com/phin-tech/vakta.git",
        ] {
            XCTAssertEqual(GitRemote(url: url), expected, url)
        }
    }

    func test_gitRemote_enterpriseHostKeepsHost() {
        XCTAssertEqual(
            GitRemote(url: "git@github.example.com:team/app.git"),
            GitRemote(host: "github.example.com", owner: "team", name: "app")
        )
    }

    func test_gitRemote_rejectsLocalPathsAndOtherShapes() {
        for url in ["/srv/git/app.git", "../app", "file:///srv/app.git", "https://github.com/only-owner", "https://gitlab.com/group/sub/app.git", ""] {
            XCTAssertNil(GitRemote(url: url), url)
        }
    }

    func test_ghRepository_omitsHostOnlyForGitHubDotCom() {
        XCTAssertEqual(GitRemote(host: "github.com", owner: "o", name: "r").ghRepository, "o/r")
        XCTAssertEqual(GitRemote(host: "github.example.com", owner: "o", name: "r").ghRepository, "github.example.com/o/r")
    }

    // MARK: config output

    func test_parseConfig_readsNulTerminatedKeyValueRecords() {
        let output = "remote.origin.url\ngit@github.com:o/r.git\u{0}branch.feat/x.remote\norigin\u{0}remote.pushdefault\nfork\u{0}"

        XCTAssertEqual(RepoCheckout.parseConfig(Data(output.utf8)), [
            "remote.origin.url": "git@github.com:o/r.git",
            "branch.feat/x.remote": "origin",
            "remote.pushdefault": "fork",
        ])
    }

    func test_parseConfig_emptyOrValuelessRecords() {
        XCTAssertEqual(RepoCheckout.parseConfig(Data()), [:])
        XCTAssertEqual(RepoCheckout.parseConfig(Data("branch.x.remote\u{0}".utf8)), [:])
    }

    // MARK: pull request target

    private func checkout(branch: String? = "feature", config: [String: String]) -> RepoCheckout {
        RepoCheckout(root: "/repo", branch: branch, config: config)
    }

    func test_target_originOnly_isHeadAndBase() {
        let target = checkout(config: ["remote.origin.url": "git@github.com:phin-tech/vakta.git"])
            .pullRequestTarget(supportedHosts: github)

        XCTAssertEqual(target, PullRequestTarget(
            repository: GitRemote(host: "github.com", owner: "phin-tech", name: "vakta"),
            branch: "feature",
            headOwner: "phin-tech"
        ))
    }

    func test_target_forkWorkflow_baseIsUpstreamHeadIsPushRemote() {
        let target = checkout(config: [
            "remote.origin.url": "git@github.com:sam/vakta.git",
            "remote.upstream.url": "https://github.com/phin-tech/vakta.git",
            "branch.feature.remote": "origin",
        ]).pullRequestTarget(supportedHosts: github)

        XCTAssertEqual(target?.repository, GitRemote(host: "github.com", owner: "phin-tech", name: "vakta"))
        XCTAssertEqual(target?.headOwner, "sam")
    }

    func test_target_pushRemotePrecedence() {
        let remotes = [
            "remote.origin.url": "git@github.com:origin-owner/r.git",
            "remote.tracking.url": "git@github.com:tracking-owner/r.git",
            "remote.default.url": "git@github.com:default-owner/r.git",
            "remote.push.url": "git@github.com:push-owner/r.git",
        ]
        func headOwner(_ extra: [String: String]) -> String? {
            checkout(config: remotes.merging(extra) { $1 }).pullRequestTarget(supportedHosts: github)?.headOwner
        }

        XCTAssertEqual(headOwner([:]), "origin-owner")
        XCTAssertEqual(headOwner(["branch.feature.remote": "tracking"]), "tracking-owner")
        XCTAssertEqual(headOwner(["branch.feature.remote": "tracking", "remote.pushdefault": "default"]), "default-owner")
        XCTAssertEqual(headOwner([
            "branch.feature.remote": "tracking",
            "remote.pushdefault": "default",
            "branch.feature.pushremote": "push",
        ]), "push-owner")
    }

    func test_target_noKeyWhenDetachedMissingRemoteOrUnsupportedHost() {
        XCTAssertNil(checkout(branch: nil, config: ["remote.origin.url": "git@github.com:o/r.git"]).pullRequestTarget(supportedHosts: github))
        XCTAssertNil(checkout(config: [:]).pullRequestTarget(supportedHosts: github))
        XCTAssertNil(checkout(config: ["remote.origin.url": "git@gitlab.com:o/r.git"]).pullRequestTarget(supportedHosts: github))
        XCTAssertNil(checkout(config: ["remote.origin.url": "/srv/git/r.git"]).pullRequestTarget(supportedHosts: github))
    }

    func test_target_upstreamOnDifferentHost_fallsBackToHeadRepository() {
        let target = checkout(config: [
            "remote.origin.url": "git@github.com:sam/r.git",
            "remote.upstream.url": "git@gitlab.com:team/r.git",
        ]).pullRequestTarget(supportedHosts: github)

        XCTAssertEqual(target?.repository, GitRemote(host: "github.com", owner: "sam", name: "r"))
    }

    // MARK: pane → key planning

    private func pane(_ id: String, _ directory: String?) -> Pane {
        Pane(id: id, tabID: "t", label: id, focused: false, status: .none, workspaceID: "w", workingDirectory: directory)
    }

    func test_plan_dedupesPanesIntoDistinctTargets() {
        let origin = ["remote.origin.url": "git@github.com:o/r.git"]
        let checkouts: [String: RepoCheckout?] = [
            "/r": RepoCheckout(root: "/r", branch: "main", config: origin),
            "/r/sub": RepoCheckout(root: "/r", branch: "main", config: origin),
            "/r-wt": RepoCheckout(root: "/r-wt", branch: "feature", config: origin),
            "/plain": nil,
        ]
        let panes = [pane("p1", "/r"), pane("p2", "/r/sub"), pane("p3", "/r-wt"), pane("p4", "/plain"), pane("p5", nil), pane("p6", "/unresolved")]

        let plan = PullRequestTargetPlanner.plan(panes: panes, checkouts: checkouts, supportedHosts: github)

        let main = PullRequestTarget(repository: GitRemote(host: "github.com", owner: "o", name: "r"), branch: "main", headOwner: "o")
        let feature = PullRequestTarget(repository: main.repository, branch: "feature", headOwner: "o")
        XCTAssertEqual(plan.targetsByPaneID, ["p1": main, "p2": main, "p3": feature])
        XCTAssertEqual(plan.targets, [main, feature])
        XCTAssertEqual(plan.repositories, [main.repository])
    }

    // MARK: resolution cache

    func test_directoriesToResolve_newAndStaleOnly_andPrunesUnused() {
        let now = Date(timeIntervalSince1970: 1_000)
        let cache: [String: RepoCheckoutCacheEntry] = [
            "/fresh": RepoCheckoutCacheEntry(checkout: nil, resolvedAt: now.addingTimeInterval(-10)),
            "/stale": RepoCheckoutCacheEntry(checkout: nil, resolvedAt: now.addingTimeInterval(-120)),
            "/gone": RepoCheckoutCacheEntry(checkout: nil, resolvedAt: now),
        ]

        let plan = RepoCheckoutCachePlanner.plan(
            directories: ["/fresh", "/stale", "/new"],
            cache: cache,
            now: now,
            maxAge: 60
        )

        XCTAssertEqual(plan.toResolve, ["/stale", "/new"])
        XCTAssertEqual(plan.toPrune, ["/gone"])
    }
}
