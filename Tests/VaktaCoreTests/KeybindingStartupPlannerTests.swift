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
    private func binding(_ key: UInt16, action: AppCommand = .toggleSidebar, modifiers: NSEvent.ModifierFlags = .control) -> Keybinding {
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

    // vakta copy/paste/cut -- standard ⌘C/⌘V/⌘X defaults, rebindable like
    // every other `AppCommand`. Asserted here by chord (modifiers +
    // physical key code) rather than by action name: `AppCommand`
    // doesn't have `.copy`/`.paste`/`.cut` cases yet (RED), and these three
    // cases alone are enough to prove the chords exist without depending on
    // the still-to-be-added enum surface. kVK_ANSI_C = 8, kVK_ANSI_V = 9,
    // kVK_ANSI_X = 7 (Carbon HIToolbox/Events.h).
    private static let cKeyCode: UInt16 = 8
    private static let vKeyCode: UInt16 = 9
    private static let xKeyCode: UInt16 = 7

    private func hasCommandChord(_ bindings: [Keybinding], keyCode: UInt16) -> Bool {
        bindings.contains { $0.modifierMask == [.command] && $0.keyCode == keyCode }
    }

    func test_missing_seedsDefaults_includesCopyPasteCutChords() {
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .missing) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.cKeyCode), "⌘C must be a default copy chord")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.vKeyCode), "⌘V must be a default paste chord")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.xKeyCode), "⌘X must be a default cut chord")
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_versionThree_addsCopyPasteCutChordsAndPersists() {
        let payload = StoredKeybindingsPayload(version: 3, bindings: [])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.cKeyCode))
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.vKeyCode))
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.xKeyCode))
        XCTAssertTrue(shouldPersist, "the v3->v4 migration ran and must be written back")
    }

    func test_loaded_versionThree_chordAlreadyTakenBySomethingElse_skipsOnlyThatChord_stillAddsOthersAndPersists() {
        // A user who rebound ⌘C to an existing action before this migration
        // ever ran keeps that binding; the migration must not clobber it,
        // but ⌘V/⌘X (untouched) still get their new defaults.
        let conflicting = binding(Self.cKeyCode, action: .toggleSidebar, modifiers: .command)
        let payload = StoredKeybindingsPayload(version: 3, bindings: [conflicting])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(bindings.contains(conflicting), "the pre-existing ⌘C binding must survive untouched")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.vKeyCode), "⌘V's chord is free and must still be added")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.xKeyCode), "⌘X's chord is free and must still be added")
        XCTAssertTrue(shouldPersist, "the migration adding ⌘V/⌘X must be written back even though ⌘C was skipped")
    }

    // vakta select-all/close-window -- v4->v5 default chords: ⌘A selects all,
    // ⌘W closes the front window. Asserted by chord, same reasoning as the
    // copy/paste/cut block above. kVK_ANSI_A = 0, kVK_ANSI_W = 13.
    //
    // Close Window must stay a normal, user-clearable binding like every
    // other action: some users route ⌘W to a terminal multiplexer running
    // *inside* the session (e.g. closing a herdr pane) and clear Vakta's own
    // ⌘W so the keystroke reaches the terminal instead -- see
    // `Keybinding.defaults`'s existing "clear the binding to hand that key
    // back to the terminal" note. No test asserts it can't be cleared; the
    // clearability comes for free from every action going through the same
    // `KeybindingMatcher.clearBinding` path (see `KeybindingMatcherRoutingTests`).
    private static let aKeyCode: UInt16 = 0
    private static let wKeyCode: UInt16 = 13

    func test_missing_seedsDefaults_includesSelectAllAndCloseWindowChords() {
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .missing) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.aKeyCode), "⌘A must be a default select-all chord")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.wKeyCode), "⌘W must be a default close-window chord")
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_versionFour_addsSelectAllAndCloseWindowChordsAndPersists() {
        let payload = StoredKeybindingsPayload(version: 4, bindings: [])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.aKeyCode))
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.wKeyCode))
        XCTAssertTrue(shouldPersist, "the v4->v5 migration ran and must be written back")
    }

    func test_loaded_versionFour_closeWindowChordAlreadyTakenBySomethingElse_skipsOnlyThatChord_stillAddsSelectAllAndPersists() {
        // Mirrors the herdr use case directly: a user who already rebound
        // ⌘W to something else (or -- once this ships -- cleared it and
        // rebound it elsewhere) before this migration ever ran keeps that
        // binding untouched.
        let conflicting = binding(Self.wKeyCode, action: .toggleSidebar, modifiers: .command)
        let payload = StoredKeybindingsPayload(version: 4, bindings: [conflicting])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(bindings.contains(conflicting), "the pre-existing ⌘W binding must survive untouched")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.aKeyCode), "⌘A's chord is free and must still be added")
        XCTAssertTrue(shouldPersist, "the migration adding ⌘A must be written back even though ⌘W was skipped")
    }

    // vakta font-size zoom -- v5->v6 default chords: ⌘= increases, ⌘- decreases,
    // ⌘0 resets, mirroring Terminal.app's own convention. Verified against
    // the pinned GhosttyKit.xcframework binary (`strings ... | grep
    // increase_font_size` etc.) that "increase_font_size"/"decrease_font_size"/
    // "reset_font_size" are real embedded binding-action names, same
    // verification style as `SessionStore.requestClose`'s "close_surface".
    // kVK_ANSI_Equal = 24, kVK_ANSI_Minus = 27, kVK_ANSI_0 = 29.
    private static let equalKeyCode: UInt16 = 24
    private static let minusKeyCode: UInt16 = 27
    private static let zeroKeyCode: UInt16 = 29

    func test_missing_seedsDefaults_includesFontSizeZoomChords() {
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .missing) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.equalKeyCode), "⌘= must be a default increase-font-size chord")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.minusKeyCode), "⌘- must be a default decrease-font-size chord")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.zeroKeyCode), "⌘0 must be a default reset-font-size chord")
        XCTAssertTrue(shouldPersist)
    }

    func test_loaded_versionFive_addsFontSizeZoomChordsAndPersists() {
        let payload = StoredKeybindingsPayload(version: 5, bindings: [])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.equalKeyCode))
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.minusKeyCode))
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.zeroKeyCode))
        XCTAssertTrue(shouldPersist, "the v5->v6 migration ran and must be written back")
    }

    func test_loaded_versionFive_resetChordAlreadyTakenBySomethingElse_skipsOnlyThatChord_stillAddsOthersAndPersists() {
        let conflicting = binding(Self.zeroKeyCode, action: .toggleSidebar, modifiers: .command)
        let payload = StoredKeybindingsPayload(version: 5, bindings: [conflicting])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(bindings.contains(conflicting), "the pre-existing ⌘0 binding must survive untouched")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.equalKeyCode), "⌘='s chord is free and must still be added")
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.minusKeyCode), "⌘-'s chord is free and must still be added")
        XCTAssertTrue(shouldPersist, "the migration adding ⌘=/⌘- must be written back even though ⌘0 was skipped")
    }

    // ⌘, open-preferences -- v6->v7 default (macOS's own Preferences chord).
    // kVK_ANSI_Comma = 43.
    private static let commaKeyCode: UInt16 = 43

    func test_missing_seedsDefaults_includesOpenPreferencesChord() {
        guard case .use(let bindings, _) = KeybindingStartupPlanner.plan(for: .missing) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(
            bindings.contains { $0.modifierMask == [.command] && $0.keyCode == Self.commaKeyCode && $0.action == .openPreferences },
            "⌘, must be a default open-preferences chord"
        )
    }

    func test_loaded_versionSix_addsOpenPreferencesChordAndPersists() {
        let payload = StoredKeybindingsPayload(version: 6, bindings: [])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(hasCommandChord(bindings, keyCode: Self.commaKeyCode))
        XCTAssertTrue(shouldPersist, "the v6->v7 migration ran and must be written back")
    }

    func test_loaded_versionSix_commaChordAlreadyTaken_isNotOverwritten() {
        let conflicting = binding(Self.commaKeyCode, action: .toggleSidebar, modifiers: .command)
        let payload = StoredKeybindingsPayload(version: 6, bindings: [conflicting])
        guard case .use(let bindings, _) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertTrue(bindings.contains(conflicting), "a pre-existing ⌘, binding must survive untouched")
        XCTAssertFalse(
            bindings.contains { $0.keyCode == Self.commaKeyCode && $0.action == .openPreferences },
            "open-preferences must not be force-added onto an already-taken ⌘,"
        )
    }

    func test_loaded_currentVersion_userClearedOpenPreferences_doesNotReaddIt() {
        // A file already at currentVersion has migrated; clearing ⌘, must stick.
        let payload = StoredKeybindingsPayload(version: KeybindingFileCodec.currentVersion, bindings: [])
        guard case .use(let bindings, let shouldPersist) = KeybindingStartupPlanner.plan(for: .loaded(payload)) else {
            return XCTFail("unreachable")
        }
        XCTAssertFalse(bindings.contains { $0.action == .openPreferences })
        XCTAssertFalse(shouldPersist)
    }
}
