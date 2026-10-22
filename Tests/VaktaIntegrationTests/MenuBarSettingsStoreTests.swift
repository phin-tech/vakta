//
//  MenuBarSettingsStoreTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the menu-bar/SketchyBar toggles against a temporary
//  storage root: first-launch seed, persistence across a restart, and a
//  corrupt file left untouched.

import XCTest
@testable import Vakta

@MainActor
final class MenuBarSettingsStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_firstLaunch_seedsMenuBarOnSketchyBarOffAndWritesTheFile() {
        let store = MenuBarSettingsStore(root: root)

        XCTAssertTrue(store.showsMenuBarItem)
        XCTAssertFalse(store.showsSketchyBarItem)
        guard case .loaded(let saved) = MenuBarSettingsPersistence.load(root: root) else {
            return XCTFail("expected the seeded file")
        }
        XCTAssertEqual(saved, MenuBarSettings(showsMenuBarItem: true, showsSketchyBarItem: false))
    }

    func test_toggles_surviveARestart() {
        let store = MenuBarSettingsStore(root: root)
        store.showsMenuBarItem = false
        store.showsSketchyBarItem = true

        let restored = MenuBarSettingsStore(root: root)
        XCTAssertFalse(restored.showsMenuBarItem)
        XCTAssertTrue(restored.showsSketchyBarItem)
    }

    func test_corruptFile_fallsBackToDefaultsWithoutOverwriting() throws {
        let fileURL = MenuBarSettingsPersistence.store(root: root).fileURL
        try Data("not json".utf8).write(to: fileURL)

        let store = MenuBarSettingsStore(root: root)

        XCTAssertTrue(store.showsMenuBarItem)
        XCTAssertFalse(store.showsSketchyBarItem)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "not json")
    }
}
