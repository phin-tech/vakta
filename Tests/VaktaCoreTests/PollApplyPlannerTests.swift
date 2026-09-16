//
//  PollApplyPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `AgentStatusApplyPlanner`, `DiscoveryApplyPlanner`,
//  and `DockBadgePlanner`: what a completed background poll should keep once
//  applied against current live state.

import XCTest
@testable import Vakta

final class AgentStatusApplyPlannerTests: XCTestCase {
    func test_accepted_liveSession_isKeptWithItsPreviousStatus() {
        let id = UUID()
        let accepted = AgentStatusApplyPlanner.accepted(
            [AgentStatusUpdate(sessionID: id, status: .working)],
            liveSessionIDs: [id],
            previous: [id: .idle]
        )
        XCTAssertEqual(accepted, [AcceptedAgentStatusUpdate(sessionID: id, previous: .idle, status: .working)])
    }

    func test_accepted_removedSession_isDropped() {
        // A session closed while its status query was in flight: the query
        // result must not resurrect a status entry for it.
        let removedID = UUID()
        let accepted = AgentStatusApplyPlanner.accepted(
            [AgentStatusUpdate(sessionID: removedID, status: .attention)],
            liveSessionIDs: [],
            previous: [:]
        )
        XCTAssertEqual(accepted, [])
    }

    func test_accepted_mixOfLiveAndRemoved_keepsOnlyLive() {
        let live = UUID()
        let removed = UUID()
        let accepted = AgentStatusApplyPlanner.accepted(
            [AgentStatusUpdate(sessionID: live, status: .idle), AgentStatusUpdate(sessionID: removed, status: .attention)],
            liveSessionIDs: [live],
            previous: [:]
        )
        XCTAssertEqual(accepted.map(\.sessionID), [live])
    }

    func test_accepted_noPreviousValue_previousIsNil() {
        let id = UUID()
        let accepted = AgentStatusApplyPlanner.accepted(
            [AgentStatusUpdate(sessionID: id, status: .working)],
            liveSessionIDs: [id],
            previous: [:]
        )
        XCTAssertEqual(accepted.first?.previous, nil)
    }
}

final class DiscoveryApplyPlannerTests: XCTestCase {
    private let profile = Profile(name: "p", command: "herdr", arguments: "--session {name}")

    func test_accepted_profileStillPresentWithMatchingTarget_isKept() {
        let target = LaunchTargetResolver.resolve(profile)
        let results = [DiscoveryQueryResult(profileID: profile.id, queriedTarget: target, result: .sessions(["a"]))]
        XCTAssertEqual(
            DiscoveryApplyPlanner.accepted(results, currentProfiles: [profile]),
            [profile.id: .sessions(["a"])]
        )
    }

    func test_accepted_profileDeleted_isDropped() {
        let target = LaunchTargetResolver.resolve(profile)
        let results = [DiscoveryQueryResult(profileID: profile.id, queriedTarget: target, result: .sessions(["a"]))]
        XCTAssertEqual(DiscoveryApplyPlanner.accepted(results, currentProfiles: []), [:])
    }

    func test_accepted_profileEditedToADifferentTarget_isDropped() {
        // The query started before the edit; by the time it completes the
        // profile resolves to a different target than what was actually
        // queried -- the stale result must not be applied.
        let queriedTarget = LaunchTargetResolver.resolve(profile)
        var editedProfile = profile
        editedProfile.command = "tmux"
        let results = [DiscoveryQueryResult(profileID: profile.id, queriedTarget: queriedTarget, result: .sessions(["a"]))]
        XCTAssertEqual(DiscoveryApplyPlanner.accepted(results, currentProfiles: [editedProfile]), [:])
    }

    func test_accepted_unrelatedProfileUnaffectedByAnothersStaleResult() {
        let target = LaunchTargetResolver.resolve(profile)
        let otherProfile = Profile(name: "other", command: "tmux")
        let otherTarget = LaunchTargetResolver.resolve(otherProfile)
        var editedProfile = profile
        editedProfile.command = "shell-does-not-exist"

        let results = [
            DiscoveryQueryResult(profileID: profile.id, queriedTarget: target, result: .sessions(["a"])),
            DiscoveryQueryResult(profileID: otherProfile.id, queriedTarget: otherTarget, result: .sessions(["b"]))
        ]
        // `profile` was edited (dropped); `otherProfile` is untouched (kept).
        let accepted = DiscoveryApplyPlanner.accepted(results, currentProfiles: [editedProfile, otherProfile])
        XCTAssertNil(accepted[profile.id])
        XCTAssertEqual(accepted[otherProfile.id], .sessions(["b"]))
    }
}

final class DockBadgePlannerTests: XCTestCase {
    func test_label_noAttentionStatuses_isNil() {
        XCTAssertNil(DockBadgePlanner.label(for: [.working, .idle, .none]))
    }

    func test_label_someAttentionStatuses_isTheCount() {
        XCTAssertEqual(DockBadgePlanner.label(for: [.attention, .working, .attention]), "2")
    }

    func test_label_unavailableStatus_doesNotCountTowardTheBadge() {
        XCTAssertNil(DockBadgePlanner.label(for: [.unavailable, .unavailable]))
    }
}
