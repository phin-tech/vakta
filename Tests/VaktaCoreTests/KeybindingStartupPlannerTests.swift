//
//  KeybindingStartupPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `KeybindingStartupPlanner`: the startup decision
//  from a `FileLoadOutcome<StoredKeybindingsPayload>` to in-memory bindings +
//  whether to persist, with no file I/O or AppKit event monitor.

import AppKit
import XCTest
@testable import Vakta

final class KeybindingStartupPlannerTests: XCTestCase {
    private func binding(_ key: UInt16, action: KeybindingAction = .toggleSidebar, modifiers: NSEvent.ModifierFlags = .control) -> Keybinding {
        Keybinding(modifierMask: modifiers, keyCode: key, action: action)
    }

    func test_missing_seedsDefaultsAndPersists() {
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .missing) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(bindings, Keybinding.defaults)
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_currentVersion_keepsBindingsAsIsAndDoesNotPersist() {
        let payload = StoredKeybindingsPayload(version: KeybindingFileCodec.currentVersion, bindings: [binding(1)])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(bindings, [binding(1)])
        XCTAssertFalse(shouldPersist, "an already-current file must not be rewritten on every launch")
    }

    func test_loaded_versionOne_addsSwitcherAndQuitDefaultsAndPersists() {
        let payload = StoredKeybindingsPayload(version: 1, bindings: [])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(bindings.contains { $0.action == .openSessionSwitcher })
        XCTAssertTrue(bindings.contains { $0.action == .quit })
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_currentVersion_userClearedAMigratedDefault_doesNotReaddIt() {
        // Once a file is saved at `currentVersion`, no further migration
        // steps run -- a binding the user cleared after a prior migration
        // must stay cleared on every subsequent launch.
        let payload = StoredKeybindingsPayload(version: KeybindingFileCodec.currentVersion, bindings: [])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertFalse(bindings.contains { $0.action == .openSessionSwitcher })
        XCTAssertFalse(bindings.contains { $0.action == .quit })
        XCTAssertFalse(shouldPersist)
    }

    func test_loaded_versionOne_switcherChordAlreadyTakenBySomethingElse_doesNotOverwriteIt_butStillAddsQuit() {
        let conflicting = binding(Keybinding.kKeyCode, action: .toggleSidebar, modifiers: .command)
        let payload = StoredKeybindingsPayload(version: 1, bindings: [conflicting])
        guard case .use(let bindings, _) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(bindings.contains(conflicting), "the pre-existing binding on that chord must survive")
        XCTAssertFalse(bindings.contains { $0.action == .openSessionSwitcher }, "its default chord is taken, so it must not be added")
        XCTAssertTrue(bindings.contains { $0.action == .quit }, "an unrelated chord's migration must still apply")
    }

    func test_corrupt_fallsBackToDefaultsInMemory_withoutPersisting() {
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .corrupt(bytes: Data("garbage".utf8))) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(bindings, Keybinding.defaults)
        XCTAssertFalse(shouldPersist, "a corrupt file must not be overwritten with reseeded defaults")
    }

    func test_unreadable_fallsBackToDefaultsInMemory_withoutPersisting() {
        struct DummyError: Error {}
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .unreadable(DummyError())) else {
            return XCTFail("unreachable")
        }
        XCTAssertEqual(bindings, Keybinding.defaults)
        XCTAssertFalse(shouldPersist, "an unreadable file must not be overwritten with reseeded defaults")
    }
}
