//
//  TargetResolutionTests.swift
//  GitHubCoreTests
//
//  A context snapshot with gitRoot/branch not yet populated for a pane
//  must not drop that pane's last-known PR target (the panel flicker bug).

import XCTest
@testable import GitHubCore

final class TargetResolutionTests: XCTestCase {
    static let target = PullRequestTarget(
        repository: GitRemote(host: "github.com", owner: "phin-tech", name: "vakta"), branch: "feature", headOwner: "phin-tech"
    )

    func test_missingGitInfoThisSnapshot_keepsTheLastKnownTarget() {
        let previous = ["pane-1": Self.target]
        let resolved: [String: PullRequestTarget??] = ["pane-1": .none]
        XCTAssertEqual(TargetResolution.next(resolved: resolved, previous: previous)["pane-1"], Self.target)
    }

    func test_resolvedTarget_replacesThePreviousOne() {
        let other = PullRequestTarget(repository: Self.target.repository, branch: "other", headOwner: "phin-tech")
        let previous = ["pane-1": Self.target]
        let resolved: [String: PullRequestTarget??] = ["pane-1": .some(.some(other))]
        XCTAssertEqual(TargetResolution.next(resolved: resolved, previous: previous)["pane-1"], other)
    }

    func test_explicitlyNoTarget_clearsThePane_evenWithAPreviousOne() {
        let previous = ["pane-1": Self.target]
        let resolved: [String: PullRequestTarget??] = ["pane-1": .some(.none)]
        XCTAssertNil(TargetResolution.next(resolved: resolved, previous: previous)["pane-1"])
    }

    func test_paneNoLongerPresent_isDropped() {
        let previous = ["pane-1": Self.target]
        XCTAssertTrue(TargetResolution.next(resolved: [:], previous: previous).isEmpty)
    }
}
