//
//  PersistenceFailureCenterTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving a real `PersistedFileStore.save` failure reaches
//  `PersistenceFailureCenter` -- the actual notification post/observe path,
//  not just the pure message formatting (`PersistenceFailureMessageTests`).

import XCTest
@testable import Vakta

final class PersistenceFailureCenterTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceFailureCenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    @MainActor
    func test_saveFailure_isObservedByPersistenceFailureCenter() throws {
        let center = PersistenceFailureCenter()
        XCTAssertNil(center.latestMessage)

        let missingRoot = tempDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
        let store = PersistedFileStore(root: missingRoot, fileName: "notifications.json", codec: JSONCodec<NotificationSettings>())

        guard case .failure = store.save(NotificationSettings()) else {
            return XCTFail("expected the save to fail")
        }

        let message = try XCTUnwrap(center.latestMessage)
        XCTAssertTrue(message.contains("notifications.json"))
    }

    @MainActor
    func test_saveSuccess_doesNotChangeLatestMessage() {
        let center = PersistenceFailureCenter()
        let store = PersistedFileStore(root: tempDirectory, fileName: "notifications.json", codec: JSONCodec<NotificationSettings>())

        guard case .success = store.save(NotificationSettings()) else {
            return XCTFail("expected the save to succeed")
        }
        XCTAssertNil(center.latestMessage)
    }

    @MainActor
    func test_dismiss_clearsTheMessage() {
        let center = PersistenceFailureCenter()
        let missingRoot = tempDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
        let store = PersistedFileStore(root: missingRoot, fileName: "notifications.json", codec: JSONCodec<NotificationSettings>())
        _ = store.save(NotificationSettings())
        XCTAssertNotNil(center.latestMessage)

        center.dismiss()
        XCTAssertNil(center.latestMessage)
    }
}
