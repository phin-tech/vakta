//
//  WorkspaceStartupPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `WorkspaceStartupPlanner`.

import XCTest
@testable import Vakta

final class WorkspaceStartupPlannerTests: XCTestCase {
    private let profileA = Profile.herdr
    private let profileB = Profile.tmux

    private func record(_ name: String, profile: Profile, workingDirectory: String? = nil, customName: String? = nil) -> SessionRecord {
        SessionRecord(profileID: profile.id, sessionName: name, customName: customName, workingDirectory: workingDirectory)
    }

    func test_missing_restoresNothingAndPersists() {
        guard case .restore(let toCreate, let unresolved, let selected, let shouldPersist) =
            WorkspaceStartupPlanner.plan(for: .missing, profiles: [profileA]) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toCreate, [])
        XCTAssertEqual(unresolved, [])
        XCTAssertNil(selected)
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_allRecordsResolve_createsThemAllAndDoesNotPersist() {
        let one = record("one", profile: profileA)
        let two = record("two", profile: profileB)
        let payload = WorkspacePayload(records: [one, two], selectedSessionName: "two")

        guard case .restore(let toCreate, let unresolved, let selected, let shouldPersist) =
            WorkspaceStartupPlanner.plan(for: .loaded(payload), profiles: [profileA, profileB]) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toCreate, [
            ResolvedSessionRecord(record: one, profile: profileA),
            ResolvedSessionRecord(record: two, profile: profileB)
        ])
        XCTAssertEqual(unresolved, [])
        XCTAssertEqual(selected, "two")
        XCTAssertFalse(shouldPersist, "already-correct saved records must not be rewritten on every launch")
    }

    func test_loaded_recordWithDeletedProfile_isUnresolvedRatherThanLaunchedUnderASubstitute() {
        var deletedProfile = Profile.shell
        deletedProfile.id = UUID()
        let orphan = record("orphan", profile: deletedProfile)
        let survivor = record("survivor", profile: profileA)
        let payload = WorkspacePayload(records: [orphan, survivor], selectedSessionName: nil)

        guard case .restore(let toCreate, let unresolved, _, let shouldPersist) =
            WorkspaceStartupPlanner.plan(for: .loaded(payload), profiles: [profileA]) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toCreate, [ResolvedSessionRecord(record: survivor, profile: profileA)])
        XCTAssertEqual(unresolved, [orphan], "a record whose profile is gone must not be silently launched under a substitute")
        XCTAssertFalse(shouldPersist, "unresolved records must stay on disk for possible manual recovery")
    }

    func test_loaded_workingDirectoryOverride_isCarriedIntoTheResolvedRecord() {
        let withOverride = record("one", profile: profileA, workingDirectory: "/tmp/project")
        let payload = WorkspacePayload(records: [withOverride], selectedSessionName: nil)

        guard case .restore(let toCreate, _, _, _) =
            WorkspaceStartupPlanner.plan(for: .loaded(payload), profiles: [profileA]) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toCreate.first?.record.workingDirectory, "/tmp/project")
    }

    func test_loaded_emptyRecords_restoresNothingAndDoesNotPersist() {
        // Reachable when every session was closed before the last save
        // (`saveWorkspace()` still writes `records: []`), distinct from
        // `.missing` (no file at all yet).
        let payload = WorkspacePayload(records: [], selectedSessionName: nil)
        guard case .restore(let toCreate, let unresolved, let selected, let shouldPersist) =
            WorkspaceStartupPlanner.plan(for: .loaded(payload), profiles: [profileA]) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toCreate, [])
        XCTAssertEqual(unresolved, [])
        XCTAssertNil(selected)
        XCTAssertFalse(shouldPersist, "an already-empty saved workspace must not be rewritten on every launch")
    }

    func test_corrupt_restoresNothingInMemory_withoutPersisting() {
        guard case .restore(let toCreate, let unresolved, let selected, let shouldPersist) =
            WorkspaceStartupPlanner.plan(for: .corrupt(bytes: Data("x".utf8)), profiles: [profileA]) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toCreate, [])
        XCTAssertEqual(unresolved, [])
        XCTAssertNil(selected)
        XCTAssertFalse(shouldPersist, "a corrupt workspace file must not be overwritten by the recovery fallback")
    }

    func test_unreadable_restoresNothingInMemory_withoutPersisting() {
        struct DummyError: Error {}
        guard case .restore(let toCreate, let unresolved, let selected, let shouldPersist) =
            WorkspaceStartupPlanner.plan(for: .unreadable(DummyError()), profiles: [profileA]) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toCreate, [])
        XCTAssertEqual(unresolved, [])
        XCTAssertNil(selected)
        XCTAssertFalse(shouldPersist, "an unreadable workspace file must not be overwritten by the recovery fallback")
    }
}
