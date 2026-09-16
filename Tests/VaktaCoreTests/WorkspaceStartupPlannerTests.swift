//
//  WorkspaceStartupPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `WorkspaceStartupPlanner`.

import XCTest
@testable import Vakta

final class WorkspaceStartupPlannerTests: XCTestCase {
    private func record(_ name: String) -> SessionRecord {
        SessionRecord(profileID: UUID(), sessionName: name, customName: nil)
    }

    func test_missing_restoresNothingAndPersists() {
        guard case .restore(let records, let shouldPersist) = WorkspaceStartupPlanner.plan(for: .missing) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(records, [])
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_restoresSavedRecords_withoutPersisting() {
        let saved = [record("one"), record("two")]
        guard case .restore(let records, let shouldPersist) = WorkspaceStartupPlanner.plan(for: .loaded(saved)) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(records, saved)
        XCTAssertFalse(shouldPersist, "already-correct saved records must not be rewritten on every launch")
    }

    func test_corrupt_restoresNothingInMemory_withoutPersisting() {
        guard case .restore(let records, let shouldPersist) = WorkspaceStartupPlanner.plan(for: .corrupt(bytes: Data("x".utf8))) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(records, [])
        XCTAssertFalse(shouldPersist, "a corrupt workspace file must not be overwritten by the recovery fallback")
    }

    func test_unreadable_restoresNothingInMemory_withoutPersisting() {
        struct DummyError: Error {}
        guard case .restore(let records, let shouldPersist) = WorkspaceStartupPlanner.plan(for: .unreadable(DummyError())) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(records, [])
        XCTAssertFalse(shouldPersist, "an unreadable workspace file must not be overwritten by the recovery fallback")
    }
}
