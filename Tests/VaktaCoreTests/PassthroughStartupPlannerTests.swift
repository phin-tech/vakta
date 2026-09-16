//
//  PassthroughStartupPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `PassthroughStartupPlanner`.

import XCTest
@testable import Vakta

final class PassthroughStartupPlannerTests: XCTestCase {
    func test_missing_seedsShiftAndPersists() {
        guard case .use(let toggle, let shouldPersist) = PassthroughStartupPlanner.plan(for: .missing) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toggle, .shift)
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_usesSavedToggle_withoutPersisting() {
        guard case .use(let toggle, let shouldPersist) = PassthroughStartupPlanner.plan(for: .loaded(.command)) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toggle, .command)
        XCTAssertFalse(shouldPersist)
    }

    func test_corrupt_fallsBackToShiftInMemory_withoutPersisting() {
        guard case .use(let toggle, let shouldPersist) = PassthroughStartupPlanner.plan(for: .corrupt(bytes: Data("x".utf8))) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toggle, .shift)
        XCTAssertFalse(shouldPersist, "a corrupt file must not be overwritten with a reseeded default")
    }

    func test_unreadable_fallsBackToShiftInMemory_withoutPersisting() {
        struct DummyError: Error {}
        guard case .use(let toggle, let shouldPersist) = PassthroughStartupPlanner.plan(for: .unreadable(DummyError())) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(toggle, .shift)
        XCTAssertFalse(shouldPersist, "an unreadable file must not be overwritten with a reseeded default")
    }
}
