//
//  AppSettingsStoresTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the simple settings stores (`AppearanceStore`,
//  `SidebarSettingsStore`, `TerminalSettingsStore`, `NotificationSettingsStore`)
//  now that each is migrated onto `PersistedFileStore` with an injected root.
//  For each: first launch seeds and persists defaults, and a corrupt file is
//  recovered from in-memory without being overwritten on disk.

import XCTest
@testable import Vakta

final class AppSettingsStoresTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsStoresTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: AppearanceStore

    @MainActor
    func test_appearanceStore_firstLaunch_seedsDefaultsAndWritesFile() {
        let store = AppearanceStore(root: tempDirectory)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertEqual(store.sidebarFont, .system)

        guard case .loaded(let settings) = AppearancePersistence.load(root: tempDirectory) else {
            return XCTFail("first launch must persist the seeded defaults")
        }
        XCTAssertEqual(settings, AppearanceSettings())
    }

    @MainActor
    func test_appearanceStore_corruptFile_usesDefaultsInMemory_butDoesNotOverwriteFile() throws {
        let fileURL = AppearancePersistence.store(root: tempDirectory).fileURL
        let corruptBytes = Data("{ not valid".utf8)
        try corruptBytes.write(to: fileURL)

        let store = AppearanceStore(root: tempDirectory)
        XCTAssertEqual(store.appearance, .system)

        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    // MARK: SidebarSettingsStore

    @MainActor
    func test_sidebarSettingsStore_firstLaunch_seedsDefaultsAndWritesFile() {
        let store = SidebarSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.collapseStyle, .icons)

        guard case .loaded(let style) = SidebarSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("first launch must persist the seeded default")
        }
        XCTAssertEqual(style, .icons)
    }

    @MainActor
    func test_sidebarSettingsStore_corruptFile_usesDefaultInMemory_butDoesNotOverwriteFile() throws {
        let fileURL = SidebarSettingsPersistence.store(root: tempDirectory).fileURL
        let corruptBytes = Data("garbage".utf8)
        try corruptBytes.write(to: fileURL)

        let store = SidebarSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.collapseStyle, .icons)

        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    // MARK: TerminalSettingsStore

    @MainActor
    func test_terminalSettingsStore_firstLaunch_seedsDefaultsAndWritesFile() {
        let store = TerminalSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.snapshot, TerminalSettings())

        guard case .loaded(let settings) = TerminalSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("first launch must persist the seeded defaults")
        }
        XCTAssertEqual(settings, TerminalSettings())
    }

    @MainActor
    func test_terminalSettingsStore_corruptFile_usesDefaultsInMemory_butDoesNotOverwriteFile() throws {
        let fileURL = TerminalSettingsPersistence.store(root: tempDirectory).fileURL
        let corruptBytes = Data("garbage".utf8)
        try corruptBytes.write(to: fileURL)

        let store = TerminalSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.snapshot, TerminalSettings())

        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    // MARK: NotificationSettingsStore

    @MainActor
    func test_notificationSettingsStore_firstLaunch_seedsDefaultsAndWritesFile() {
        let store = NotificationSettingsStore(root: tempDirectory)
        XCTAssertTrue(store.notifyOnAttention)
        XCTAssertTrue(store.notifyOnFinished)
        XCTAssertTrue(store.bounceDock)

        guard case .loaded(let settings) = NotificationSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("first launch must persist the seeded defaults")
        }
        XCTAssertEqual(settings, NotificationSettings())
    }

    @MainActor
    func test_notificationSettingsStore_corruptFile_usesDefaultsInMemory_butDoesNotOverwriteFile() throws {
        let fileURL = NotificationSettingsPersistence.store(root: tempDirectory).fileURL
        let corruptBytes = Data("garbage".utf8)
        try corruptBytes.write(to: fileURL)

        let store = NotificationSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.notifyOnAttention, NotificationSettings().notifyOnAttention)

        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    // MARK: HerdrPreferencesStore

    @MainActor
    func test_herdrPreferencesStore_firstLaunch_seedsDefaultsAndWritesFile() {
        let store = HerdrPreferencesStore(root: tempDirectory)
        XCTAssertFalse(store.showWorkspaces)

        guard case .loaded(let preferences) = HerdrPreferencesPersistence.load(root: tempDirectory) else {
            return XCTFail("first launch must persist the seeded defaults")
        }
        XCTAssertEqual(preferences, HerdrPreferences())
    }

    @MainActor
    func test_herdrPreferencesStore_corruptFile_usesDefaultsInMemory_butDoesNotOverwriteFile() throws {
        let fileURL = HerdrPreferencesPersistence.store(root: tempDirectory).fileURL
        let corruptBytes = Data("garbage".utf8)
        try corruptBytes.write(to: fileURL)

        let store = HerdrPreferencesStore(root: tempDirectory)
        XCTAssertEqual(store.showWorkspaces, HerdrPreferences().showWorkspaces)

        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    @MainActor
    func test_herdrPreferencesStore_toggling_persistsImmediately() {
        let store = HerdrPreferencesStore(root: tempDirectory)
        store.showWorkspaces = true

        guard case .loaded(let preferences) = HerdrPreferencesPersistence.load(root: tempDirectory) else {
            return XCTFail("toggling must persist")
        }
        XCTAssertTrue(preferences.showWorkspaces)
    }
}
