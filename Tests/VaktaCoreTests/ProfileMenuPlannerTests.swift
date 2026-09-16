//
//  ProfileMenuPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `ProfileMenuPlanner.entries` and
//  `ProfileDeletionPlanner.afterDeleting`.

import XCTest
@testable import Vakta

final class ProfileMenuPlannerTests: XCTestCase {
    func test_entries_mirrorsProfilesInOrder() {
        let a = Profile(name: "A", command: "herdr")
        let b = Profile(name: "B", command: "tmux")
        XCTAssertEqual(
            ProfileMenuPlanner.entries(for: [a, b]),
            [ProfileMenuEntry(profileID: a.id, title: "A"), ProfileMenuEntry(profileID: b.id, title: "B")]
        )
    }

    func test_entries_empty_isEmpty() {
        XCTAssertEqual(ProfileMenuPlanner.entries(for: []), [])
    }

    func test_entries_reflectsARename() {
        var profile = Profile(name: "Old Name", command: "herdr")
        let entriesBefore = ProfileMenuPlanner.entries(for: [profile])
        XCTAssertEqual(entriesBefore.first?.title, "Old Name")

        profile.name = "New Name"
        let entriesAfter = ProfileMenuPlanner.entries(for: [profile])
        XCTAssertEqual(entriesAfter.first?.title, "New Name")
        XCTAssertEqual(entriesAfter.first?.profileID, profile.id, "identity survives the rename")
    }
}

final class ProfileDeletionPlannerTests: XCTestCase {
    func test_afterDeleting_oneOfSeveral_removesJustThatOne() {
        let a = Profile(name: "A", command: "herdr")
        let b = Profile(name: "B", command: "tmux")
        XCTAssertEqual(ProfileDeletionPlanner.afterDeleting(a.id, from: [a, b]), [b])
    }

    func test_afterDeleting_theLastProfile_reseedsBuiltInDefaults_ratherThanLeavingItEmpty() {
        let only = Profile(name: "Only", command: "herdr")
        let result = ProfileDeletionPlanner.afterDeleting(only.id, from: [only])
        XCTAssertEqual(result, [.herdr, .tmux, .shell])
    }

    func test_afterDeleting_anIDNotPresent_leavesTheListUnchanged() {
        let a = Profile(name: "A", command: "herdr")
        XCTAssertEqual(ProfileDeletionPlanner.afterDeleting(UUID(), from: [a]), [a])
    }

    func test_afterDeleting_fromAnAlreadyEmptyList_reseedsBuiltInDefaults() {
        // Defensive: shouldn't be reachable given the "never leave it empty"
        // invariant this planner itself maintains, but must not misbehave
        // if it somehow is.
        XCTAssertEqual(ProfileDeletionPlanner.afterDeleting(UUID(), from: []), [.herdr, .tmux, .shell])
    }
}
