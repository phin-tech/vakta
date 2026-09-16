//
//  SessionRecordBuilderTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `SessionRecordBuilder`, the pure extraction of
//  `SessionStore.saveWorkspace`'s working-directory diff: a session's
//  resolved working directory round-trips as `nil` (follow the profile) when
//  it matches what the profile itself would currently produce, and as an
//  explicit override only when it actually differs. Previously untested (the
//  save side of `k916`'s persistence coverage; the load/restore side is
//  covered by `WorkspaceStartupPlannerTests`).

import XCTest
@testable import Vakta

final class SessionRecordBuilderTests: XCTestCase {
    private func profile(id: UUID = UUID(), workingDirectory: String?) -> Profile {
        Profile(id: id, name: "p", command: "cmd", workingDirectory: workingDirectory, environment: [:])
    }

    func test_sessionWorkingDirectory_matchesProfile_recordsNilOverride() {
        let p = profile(workingDirectory: "/home/user")

        let record = SessionRecordBuilder.record(
            profileID: p.id,
            sessionName: "s1",
            customName: nil,
            workingDirectory: "/home/user",
            profiles: [p]
        )

        XCTAssertNil(record.workingDirectory)
    }

    func test_sessionWorkingDirectory_differsFromProfile_recordsExplicitOverride() {
        let p = profile(workingDirectory: "/home/user")

        let record = SessionRecordBuilder.record(
            profileID: p.id,
            sessionName: "s1",
            customName: nil,
            workingDirectory: "/tmp/override",
            profiles: [p]
        )

        XCTAssertEqual(record.workingDirectory, "/tmp/override")
    }

    func test_profileHasNoWorkingDirectory_sessionHasNone_recordsNilOverride() {
        let p = profile(workingDirectory: nil)

        let record = SessionRecordBuilder.record(
            profileID: p.id,
            sessionName: "s1",
            customName: nil,
            workingDirectory: nil,
            profiles: [p]
        )

        XCTAssertNil(record.workingDirectory)
    }

    func test_profileHasNoWorkingDirectory_sessionHasOne_recordsExplicitOverride() {
        let p = profile(workingDirectory: nil)

        let record = SessionRecordBuilder.record(
            profileID: p.id,
            sessionName: "s1",
            customName: nil,
            workingDirectory: "/tmp/explicit",
            profiles: [p]
        )

        XCTAssertEqual(record.workingDirectory, "/tmp/explicit")
    }

    func test_profileNoLongerExists_sessionsWorkingDirectory_isRecordedAsIs() {
        let record = SessionRecordBuilder.record(
            profileID: UUID(),
            sessionName: "s1",
            customName: nil,
            workingDirectory: "/tmp/whatever",
            profiles: []
        )

        XCTAssertEqual(record.workingDirectory, "/tmp/whatever")
    }

    func test_carriesThroughSessionNameAndCustomName() {
        let p = profile(workingDirectory: nil)

        let record = SessionRecordBuilder.record(
            profileID: p.id,
            sessionName: "s1",
            customName: "My Session",
            workingDirectory: nil,
            profiles: [p]
        )

        XCTAssertEqual(record.profileID, p.id)
        XCTAssertEqual(record.sessionName, "s1")
        XCTAssertEqual(record.customName, "My Session")
    }
}
