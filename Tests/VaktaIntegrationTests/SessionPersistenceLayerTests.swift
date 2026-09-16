//
//  SessionPersistenceLayerTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `ProfilePersistence`, `WorkspacePersistence`, and
//  `SessionSettingsPersistence` now that each is migrated onto
//  `PersistedFileStore` with an injected root. Scoped to the persistence
//  layer itself, not `SessionStore` -- its `init` spawns real multiplexer
//  child processes and is out of scope for an isolated unit test.

import XCTest
@testable import Vakta

final class SessionPersistenceLayerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPersistenceLayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func test_profilePersistence_load_afterSave_roundTrips() {
        let profiles = [Profile.herdr, Profile.tmux]
        ProfilePersistence.save(profiles, root: tempDirectory)

        guard case .loaded(let loaded) = ProfilePersistence.load(root: tempDirectory) else {
            return XCTFail("expected a loaded payload after save")
        }
        XCTAssertEqual(loaded, profiles)
    }

    func test_profilePersistence_corruptFile_isNotOverwrittenByLoad() throws {
        let fileURL = ProfilePersistence.store(root: tempDirectory).fileURL
        let corruptBytes = Data("{ not valid".utf8)
        try corruptBytes.write(to: fileURL)

        guard case .corrupt(let bytes) = ProfilePersistence.load(root: tempDirectory) else {
            return XCTFail("expected .corrupt for an undecodable file")
        }
        XCTAssertEqual(bytes, corruptBytes)
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    func test_workspacePersistence_load_afterSave_roundTrips() {
        let records = [SessionRecord(profileID: UUID(), sessionName: "one", customName: "Renamed")]
        WorkspacePersistence.save(records, root: tempDirectory)

        guard case .loaded(let loaded) = WorkspacePersistence.load(root: tempDirectory) else {
            return XCTFail("expected a loaded payload after save")
        }
        XCTAssertEqual(loaded, records)
    }

    func test_sessionSettingsPersistence_load_afterSave_roundTrips() {
        let id = UUID()
        SessionSettingsPersistence.saveDefaultProfileID(id, root: tempDirectory)

        guard case .loaded(let payload) = SessionSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("expected a loaded payload after save")
        }
        XCTAssertEqual(payload.defaultProfileID, id)
    }

    func test_sessionSettingsPersistence_load_whenMissing_returnsMissing() {
        guard case .missing = SessionSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("expected .missing for a never-written file")
        }
    }
}
