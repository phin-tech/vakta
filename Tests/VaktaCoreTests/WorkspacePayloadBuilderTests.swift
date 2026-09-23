//
//  WorkspacePayloadBuilderTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `WorkspacePayloadBuilder`, the pure part of
//  `SessionStore.saveWorkspace`: transient sessions (the tour's installer)
//  are never persisted, so a restart can't rerun an install or report an
//  unknown profile, and a transient selection isn't recorded.
//

import XCTest
@testable import Vakta

final class WorkspacePayloadBuilderTests: XCTestCase {
    private let profile = Profile(name: "herdr", command: "herdr")

    private func entry(_ name: String, transient: Bool = false) -> WorkspacePayloadBuilder.LiveSession {
        WorkspacePayloadBuilder.LiveSession(
            profileID: profile.id, sessionName: name, customName: nil,
            workingDirectory: nil, isTransient: transient
        )
    }

    func test_transientSessions_areLeftOut_inOrder() {
        let payload = WorkspacePayloadBuilder.payload(
            sessions: [entry("a"), entry("install", transient: true), entry("b")],
            selectedSessionName: "b",
            unresolvedRecords: [],
            profiles: [profile]
        )
        XCTAssertEqual(payload.records.map(\.sessionName), ["a", "b"])
        XCTAssertEqual(payload.selectedSessionName, "b")
    }

    func test_selectedTransientSession_isNotRecordedAsTheSelection() {
        let payload = WorkspacePayloadBuilder.payload(
            sessions: [entry("a"), entry("install", transient: true)],
            selectedSessionName: "install",
            unresolvedRecords: [],
            profiles: [profile]
        )
        XCTAssertNil(payload.selectedSessionName)
    }

    func test_unresolvedRecords_stillRoundTrip_afterLiveOnes() {
        let unresolved = SessionRecord(profileID: UUID(), sessionName: "gone", customName: nil, workingDirectory: nil)
        let payload = WorkspacePayloadBuilder.payload(
            sessions: [entry("a")],
            selectedSessionName: "a",
            unresolvedRecords: [unresolved],
            profiles: [profile]
        )
        XCTAssertEqual(payload.records.map(\.sessionName), ["a", "gone"])
    }
}
