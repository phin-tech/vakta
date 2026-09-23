//
//  StatusBarPreferencesStoreTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the status bar visibility preference against a temporary
//  storage root: first-launch seed, persistence across a restart, and a
//  corrupt file left untouched.

import XCTest
@testable import Vakta

@MainActor
final class StatusBarPreferencesStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusBarPreferencesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_firstLaunch_seedsAutoAndWritesTheFile() {
        let store = StatusBarPreferencesStore(root: root)

        XCTAssertEqual(store.visibility, .auto)
        guard case .loaded(let saved) = StatusBarPreferencesPersistence.load(root: root) else {
            return XCTFail("expected the seeded file")
        }
        XCTAssertEqual(saved, StatusBarPreferences(visibility: .auto))
    }

    func test_changedVisibility_survivesARestart() {
        StatusBarPreferencesStore(root: root).visibility = .autoHide

        XCTAssertEqual(StatusBarPreferencesStore(root: root).visibility, .autoHide)
    }

    func test_cycle_advancesAndPersists() {
        let store = StatusBarPreferencesStore(root: root)
        store.cycle()
        store.cycle()

        XCTAssertEqual(store.visibility, .show)
        XCTAssertEqual(StatusBarPreferencesStore(root: root).visibility, .show)
    }

    func test_corruptFile_fallsBackToAutoWithoutOverwriting() throws {
        let fileURL = StatusBarPreferencesPersistence.store(root: root).fileURL
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(StatusBarPreferencesStore(root: root).visibility, .auto)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "not json")
    }
}
