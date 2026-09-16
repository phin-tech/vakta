//
//  AppSettingsStoresTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the simple settings stores (`AppearanceStore`,
//  `SidebarSettingsStore`, `TerminalSettingsStore`, `NotificationSettingsStore`)
//  now that each is migrated onto `PersistedFileStore` with an injected root.
//  For each: first launch seeds and persists defaults, and a corrupt file is
//  recovered from in-memory without being overwritten on disk.

import AppKit
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

    @MainActor
    func test_appearanceStore_loadedFile_usesSavedValues() {
        AppearancePersistence.save(AppearanceSettings(appearance: .dark, sidebarFont: .matchTerminal), root: tempDirectory)

        let store = AppearanceStore(root: tempDirectory)

        XCTAssertEqual(store.appearance, .dark)
        XCTAssertEqual(store.sidebarFont, .matchTerminal)
    }

    @MainActor
    func test_appearanceStore_settingAppearance_persistsAndAppliesToNSApp() {
        // `NSApp` is nil until something touches `NSApplication.shared` --
        // never true in the real app (AppKit sets it during launch), but
        // this XCTest host never runs an app lifecycle.
        _ = NSApplication.shared
        let store = AppearanceStore(root: tempDirectory)

        store.appearance = .dark

        guard case .loaded(let settings) = AppearancePersistence.load(root: tempDirectory) else {
            return XCTFail("setting appearance must persist")
        }
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(NSApp.appearance, NSAppearance(named: .darkAqua))
    }

    @MainActor
    func test_appearanceStore_settingAppearanceToSystem_handsControlBackToTheOS() {
        _ = NSApplication.shared
        let store = AppearanceStore(root: tempDirectory)
        store.appearance = .dark

        store.appearance = .system

        XCTAssertNil(NSApp.appearance)
    }

    @MainActor
    func test_appearanceStore_settingSidebarFont_persists() {
        let store = AppearanceStore(root: tempDirectory)

        store.sidebarFont = .matchTerminal

        guard case .loaded(let settings) = AppearancePersistence.load(root: tempDirectory) else {
            return XCTFail("setting sidebarFont must persist")
        }
        XCTAssertEqual(settings.sidebarFont, .matchTerminal)
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

    @MainActor
    func test_sidebarSettingsStore_loadedFile_usesSavedValue() {
        SidebarSettingsPersistence.save(.hidden, root: tempDirectory)

        let store = SidebarSettingsStore(root: tempDirectory)

        XCTAssertEqual(store.collapseStyle, .hidden)
    }

    @MainActor
    func test_sidebarSettingsStore_settingCollapseStyle_persistsImmediately() {
        let store = SidebarSettingsStore(root: tempDirectory)

        store.collapseStyle = .hidden

        guard case .loaded(let style) = SidebarSettingsPersistence.load(root: tempDirectory) else {
            return XCTFail("setting collapseStyle must persist")
        }
        XCTAssertEqual(style, .hidden)
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
