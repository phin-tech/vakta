//
//  KeybindingPersistenceTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `KeybindingPersistence` (a thin `PersistedFileStore`
//  wrapper) and for `KeybindingMatcher.init(root:)`'s end-to-end startup
//  behavior against a real temporary directory -- never real Application
//  Support.

import AppKit
import XCTest
@testable import Vakta

final class KeybindingPersistenceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybindingPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func test_load_afterSave_roundTrips() {
        let bindings = [Keybinding(modifierMask: .command, keyCode: 5, action: .toggleSidebar)]
        KeybindingPersistence.save(bindings, root: tempDirectory)

        guard case .loaded(let payload) = KeybindingPersistence.load(root: tempDirectory) else {
            return XCTFail("expected a loaded payload after save")
        }
        XCTAssertEqual(payload.bindings, bindings)
        XCTAssertEqual(payload.version, KeybindingPersistence.currentVersion)
    }

    @MainActor
    func test_matcherInit_firstLaunch_seedsDefaultsAndWritesFile() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        XCTAssertEqual(matcher.bindings, Keybinding.defaults)

        guard case .loaded(let payload) = KeybindingPersistence.load(root: tempDirectory) else {
            return XCTFail("first launch must persist the seeded defaults")
        }
        XCTAssertEqual(payload.bindings, Keybinding.defaults)
    }

    @MainActor
    func test_matcherInit_corruptFile_usesDefaultsInMemory_butDoesNotOverwriteFile() throws {
        let store = KeybindingPersistence.store(root: tempDirectory)
        let corruptBytes = Data("{ not valid".utf8)
        try corruptBytes.write(to: store.fileURL)

        let matcher = KeybindingMatcher(root: tempDirectory)
        XCTAssertEqual(matcher.bindings, Keybinding.defaults)

        XCTAssertEqual(
            try Data(contentsOf: store.fileURL),
            corruptBytes,
            "a corrupt keybindings file must survive a launch that recovers with in-memory defaults"
        )
    }

    @MainActor
    func test_matcherInit_versionOneFile_migratesAndPersistsAtCurrentVersion() throws {
        let existing = [Keybinding(modifierMask: .control, keyCode: 30, action: .toggleSidebar)]
        // Write the pre-versioning legacy shape directly: a bare `[Keybinding]`
        // array, with no envelope at all.
        let data = try JSONEncoder().encode(existing)
        try data.write(to: KeybindingPersistence.store(root: tempDirectory).fileURL)

        let matcher = KeybindingMatcher(root: tempDirectory)
        XCTAssertTrue(matcher.bindings.contains { $0.action == .openSessionSwitcher })
        XCTAssertTrue(matcher.bindings.contains { $0.action == .quit })

        guard case .loaded(let payload) = KeybindingPersistence.load(root: tempDirectory) else {
            return XCTFail("migration must persist the upgraded bindings")
        }
        XCTAssertEqual(payload.version, KeybindingPersistence.currentVersion)
    }

    @MainActor
    func test_matcherInit_corruptPassthroughFile_usesShiftInMemory_butDoesNotOverwriteFile() throws {
        let store = PassthroughSettingsPersistence.store(root: tempDirectory)
        let corruptBytes = Data("not json".utf8)
        try corruptBytes.write(to: store.fileURL)

        let matcher = KeybindingMatcher(root: tempDirectory)
        XCTAssertEqual(matcher.passthroughToggle, .shift)

        XCTAssertEqual(
            try Data(contentsOf: store.fileURL),
            corruptBytes,
            "a corrupt passthrough file must survive a launch that recovers with the in-memory default"
        )
    }
}
