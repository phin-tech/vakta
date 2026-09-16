//
//  PersistenceFailureMessageTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `PersistenceFailureMessage.describe`: pure
//  formatting from a failure to a short, user-presentable message.

import XCTest
@testable import Vakta

final class PersistenceFailureMessageTests: XCTestCase {
    func test_encodingFailed_mentionsTheFileName() {
        let message = PersistenceFailureMessage.describe(
            fileName: "notifications.json",
            error: PersistedFileStoreError.encodingFailed
        )
        XCTAssertTrue(message.contains("notifications.json"))
    }

    func test_arbitraryError_mentionsTheFileNameAndUnderlyingDescription() {
        struct SomeError: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let message = PersistenceFailureMessage.describe(fileName: "profiles.json", error: SomeError())
        XCTAssertTrue(message.contains("profiles.json"))
        XCTAssertTrue(message.contains("disk full"))
    }
}
