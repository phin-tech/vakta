//
//  SidebarStatePersistenceTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `SidebarSettingsStore` now that it owns the full sidebar
//  state -- collapse style, collapsed/expanded flag, and expanded width -- so
//  the sidebar resumes exactly as the user left it across relaunches. Uses the
//  real store with an injected temp root; no mocks. The collapse-style cases
//  already covered in `AppSettingsStoresTests` are not repeated here.

import XCTest
@testable import Vakta

@MainActor
final class SidebarStatePersistenceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarStatePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func test_firstLaunch_seedsExpandedAndDefaultWidth() {
        let store = SidebarSettingsStore(root: tempDirectory)

        XCTAssertFalse(store.isCollapsed, "the sidebar starts expanded")
        XCTAssertEqual(store.expandedWidth, SidebarSettings.defaultExpandedWidth)

        guard case .loaded(let settings) = SidebarSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("first launch must persist the seeded defaults")
        }
        XCTAssertEqual(settings, SidebarSettings())
    }

    func test_loadedFile_restoresCollapsedFlagAndWidth() {
        SidebarSettingsPersistence.save(
            SidebarSettings(collapseStyle: .icons, isCollapsed: true, expandedWidth: 300),
            root: tempDirectory
        )

        let store = SidebarSettingsStore(root: tempDirectory)

        XCTAssertTrue(store.isCollapsed)
        XCTAssertEqual(store.expandedWidth, 300)
    }

    func test_settingCollapsed_persistsImmediately() {
        let store = SidebarSettingsStore(root: tempDirectory)

        store.isCollapsed = true

        guard case .loaded(let settings) = SidebarSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("collapsing must persist")
        }
        XCTAssertTrue(settings.isCollapsed)
    }

    func test_settingExpandedWidth_persistsImmediately() {
        let store = SidebarSettingsStore(root: tempDirectory)

        store.expandedWidth = 275

        guard case .loaded(let settings) = SidebarSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("resizing must persist")
        }
        XCTAssertEqual(settings.expandedWidth, 275)
    }

    func test_toggleCollapsed_flipsAndPersists() {
        let store = SidebarSettingsStore(root: tempDirectory)
        XCTAssertFalse(store.isCollapsed)

        store.toggleCollapsed()

        XCTAssertTrue(store.isCollapsed)
        guard case .loaded(let settings) = SidebarSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("toggling must persist")
        }
        XCTAssertTrue(settings.isCollapsed)
    }

    func test_collapsing_doesNotAlterExpandedWidth() {
        let store = SidebarSettingsStore(root: tempDirectory)
        store.expandedWidth = 260

        store.isCollapsed = true

        XCTAssertEqual(store.expandedWidth, 260, "collapsing preserves the width to restore on expand")
    }

    // MARK: Legacy migration across a restart (testing.md: old data + a restart)

    func test_legacyFile_migratesThenNewStateRoundTripsAfterRestart() throws {
        // Write the legacy bare-style file the old store produced.
        let fileURL = SidebarSettingsPersistence.store(root: tempDirectory).fileURL
        try JSONEncoder().encode(SidebarCollapseStyle.hidden).write(to: fileURL)

        let first = SidebarSettingsStore(root: tempDirectory)
        XCTAssertEqual(first.collapseStyle, .hidden, "legacy style is preserved")
        XCTAssertFalse(first.isCollapsed, "legacy file has no collapsed flag -- defaults to expanded")
        XCTAssertEqual(first.expandedWidth, SidebarSettings.defaultExpandedWidth)

        // The user now collapses and resizes; the file is rewritten as the new struct.
        first.isCollapsed = true
        first.expandedWidth = 288

        let second = SidebarSettingsStore(root: tempDirectory)
        XCTAssertEqual(second.collapseStyle, .hidden)
        XCTAssertTrue(second.isCollapsed)
        XCTAssertEqual(second.expandedWidth, 288)
    }

    func test_unknownStyleFile_usesDefaultsInMemory_butDoesNotOverwriteFile() throws {
        let fileURL = SidebarSettingsPersistence.store(root: tempDirectory).fileURL
        let corruptBytes = Data(#"{"collapseStyle":"sideways"}"#.utf8)
        try corruptBytes.write(to: fileURL)

        let store = SidebarSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.collapseStyle, .icons)
        XCTAssertFalse(store.isCollapsed)
        XCTAssertEqual(store.expandedWidth, SidebarSettings.defaultExpandedWidth)

        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes, "a corrupt file is never overwritten")
    }
}
