//
//  KeybindingPresetPersistenceTests.swift
//  VaktaIntegrationTests
//
//  Applying and reverting the Mac-style preset through `KeybindingMatcher`
//  against a temporary storage root: both the bindings and the record of
//  what the preset replaced survive a restart, and a missing or corrupt
//  record never blocks reverting.

import AppKit
import XCTest
@testable import Vakta

@MainActor
final class KeybindingPresetPersistenceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybindingPresetPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sortedKeys(_ bindings: [Keybinding]) -> [String] {
        bindings.map { "\($0.modifierMask.rawValue)-\($0.keyCode)-\($0.action.stableID)" }.sorted()
    }

    func test_applyThenRestart_keepsThePreset_thenRevertRestoresCustomBindings() {
        let first = KeybindingMatcher(root: root)
        first.setBinding([.control, .option], keyCode: 9, for: .splitPaneRight)
        let original = first.bindings
        XCTAssertFalse(first.isMacStylePresetApplied)

        first.applyMacStylePreset()
        XCTAssertTrue(first.isMacStylePresetApplied)

        let second = KeybindingMatcher(root: root)
        XCTAssertTrue(second.isMacStylePresetApplied, "bindings persisted")
        second.revertMacStylePreset()
        XCTAssertFalse(second.isMacStylePresetApplied)

        let third = KeybindingMatcher(root: root)
        XCTAssertEqual(sortedKeys(third.bindings), sortedKeys(original), "custom binding restored from the persisted record")
    }

    func test_revertWithACorruptRecord_stillRemovesThePresetAndRestoresDefaults() throws {
        let matcher = KeybindingMatcher(root: root)
        matcher.applyMacStylePreset()
        try Data("not json".utf8).write(to: KeybindingPresetPersistence.store(root: root).fileURL)

        let restarted = KeybindingMatcher(root: root)
        restarted.revertMacStylePreset()

        XCTAssertEqual(sortedKeys(restarted.bindings), sortedKeys(Keybinding.defaults))
    }
}
