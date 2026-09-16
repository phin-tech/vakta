//
//  ProfileDeletionPersistenceTests.swift
//  VaktaIntegrationTests
//
//  Shell case proving deleting the last profile's result actually survives
//  a restart -- not just that `ProfileDeletionPlanner`'s pure decision looks
//  right (see `ProfileMenuPlannerTests`). Simulates "restart" the same way
//  k916/njjm's tests do: save, then load from a fresh `PersistedFileStore`
//  read against the same temp root.

import XCTest
@testable import Vakta

final class ProfileDeletionPersistenceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileDeletionPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func test_deletingTheLastProfile_persistsBuiltInDefaults_survivingARestart() {
        let only = Profile(name: "Only", command: "herdr")
        ProfilePersistence.save([only], root: tempDirectory)

        // The deletion itself: SessionStore.deleteProfile's logic, applied
        // directly at the persistence layer the way SessionStore's own
        // `profiles` didSet would.
        let afterDeletion = ProfileDeletionPlanner.afterDeleting(only.id, from: [only])
        ProfilePersistence.save(afterDeletion, root: tempDirectory)

        // Simulate a restart: a fresh load against the same root.
        guard case .loaded(let reloaded) = ProfilePersistence.load(root: tempDirectory) else {
            return XCTFail("expected a loaded payload after save")
        }
        XCTAssertEqual(reloaded, [.herdr, .tmux, .shell])
        XCTAssertFalse(reloaded.isEmpty, "deleting the last profile must never persist an empty list")
    }
}
