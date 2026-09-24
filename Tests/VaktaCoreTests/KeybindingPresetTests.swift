//
//  KeybindingPresetTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the Mac-style shortcut preset: its chord table,
//  applying it (taking over chords, moving commands, recording everything
//  it replaced), the change list Preferences shows before applying, and a
//  revert that restores what was replaced without clobbering anything the
//  user changed since.

import AppKit
import XCTest
@testable import Vakta

final class KeybindingPresetTests: XCTestCase {
    private let preset = KeybindingPreset.macStyle

    private func binding(_ mask: NSEvent.ModifierFlags, _ keyCode: UInt16, _ action: AppCommand) -> Keybinding {
        Keybinding(modifierMask: mask, keyCode: keyCode, action: action)
    }

    /// Order-insensitive comparison of binding lists.
    private func assertSameBindings(_ lhs: [Keybinding], _ rhs: [Keybinding], file: StaticString = #filePath, line: UInt = #line) {
        func key(_ b: Keybinding) -> String { "\(b.modifierMask.rawValue)-\(b.keyCode)-\(b.action.stableID)" }
        XCTAssertEqual(lhs.map(key).sorted(), rhs.map(key).sorted(), file: file, line: line)
    }

    // MARK: chord table

    func test_macStyle_chordTable() {
        let expected: [Keybinding] = [
            binding([.command], 17, .newWorkspace),
            binding([.command], 2, .splitPaneRight),
            binding([.command, .shift], 2, .splitPaneDown),
            binding([.command], 13, .closePane),
            binding([.command, .shift], 13, .closeWorkspace),
            binding([.command, .shift], 36, .zoomPane),
            binding([.command, .option], 123, .focusPaneLeft),
            binding([.command, .option], 124, .focusPaneRight),
            binding([.command, .option], 126, .focusPaneUp),
            binding([.command, .option], 125, .focusPaneDown),
            binding([.command, .shift], 33, .previousWorkspace),
            binding([.command, .shift], 30, .nextWorkspace),
        ] + Keybinding.digitKeyCodes.enumerated().map { binding([.command], $0.element, .focusWorkspace($0.offset)) }

        assertSameBindings(preset.bindings, expected)
    }

    func test_macStyle_chordsAndCommandsAreUnique_andAvoidTheLeaderAndCoreMacChords() {
        let chords = preset.bindings.map { "\($0.modifierMask.rawValue)-\($0.keyCode)" }
        XCTAssertEqual(Set(chords).count, chords.count)
        XCTAssertEqual(Set(preset.bindings.map(\.action.stableID)).count, preset.bindings.count)

        let untouchable = Keybinding.defaults.filter { [.quit, .copy, .paste, .cut, .selectAll, .openSessionSwitcher, .openPreferences].contains($0.action) }
        for kept in untouchable {
            XCTAssertFalse(preset.bindings.contains { $0.modifierMask == kept.modifierMask && $0.keyCode == kept.keyCode }, "\(kept.action)")
        }
        XCTAssertFalse(preset.bindings.contains { $0.modifierMask == LeaderSettings().modifierMask && $0.keyCode == LeaderSettings().keyCode })
    }

    // MARK: apply

    func test_apply_takesOverChords_andRecordsWhatItReplaced() {
        let result = preset.apply(to: Keybinding.defaults)

        XCTAssertTrue(preset.isApplied(in: result.bindings))
        XCTAssertFalse(preset.isApplied(in: Keybinding.defaults))
        XCTAssertNil(result.bindings.first { $0.action == .closeWindow }, "⌘W now closes the pane")
        XCTAssertEqual(result.replaced, [binding([.command], 13, .closeWindow)])
        for kept in Keybinding.defaults where kept.action != .closeWindow {
            XCTAssertTrue(result.bindings.contains(kept), "\(kept.action) untouched")
        }
    }

    func test_apply_movesACommandsCustomChord_andRecordsIt() {
        let custom = binding([.control, .option], 9, .splitPaneRight)
        let result = preset.apply(to: Keybinding.defaults + [custom])

        XCTAssertFalse(result.bindings.contains(custom))
        XCTAssertTrue(result.replaced.contains(custom))
    }

    func test_changes_describeEveryChordAndWhatItDisplaces() {
        let custom = binding([.control, .option], 9, .splitPaneRight)
        let changes = preset.changes(from: Keybinding.defaults + [custom])

        XCTAssertEqual(changes.count, preset.bindings.count)
        let closePane = changes.first { $0.binding.action == .closePane }
        XCTAssertEqual(closePane?.displacedCommand, .closeWindow)
        XCTAssertNil(closePane?.previousChord)
        let split = changes.first { $0.binding.action == .splitPaneRight }
        XCTAssertEqual(split?.previousChord, custom)
        XCTAssertNil(split?.displacedCommand)
    }

    func test_applyingTwice_isStable() {
        let once = preset.apply(to: Keybinding.defaults)
        let twice = preset.apply(to: once.bindings)
        assertSameBindings(twice.bindings, once.bindings)
        XCTAssertEqual(twice.replaced, [])
    }

    // MARK: revert

    func test_revert_roundTripsIncludingCustomBindings() {
        let original = Keybinding.defaults + [binding([.control, .option], 9, .splitPaneRight)]
        let applied = preset.apply(to: original)

        assertSameBindings(preset.revert(applied.bindings, restoring: applied.replaced), original)
    }

    func test_revert_keepsAPresetChordTheUserRebound() {
        let applied = preset.apply(to: Keybinding.defaults)
        var edited = applied.bindings.filter { $0.action != .closePane }
        edited.append(binding([.command, .option], 13, .closePane))

        let reverted = preset.revert(edited, restoring: applied.replaced)

        XCTAssertTrue(reverted.contains(binding([.command, .option], 13, .closePane)), "user's own chord kept")
        XCTAssertTrue(reverted.contains(binding([.command], 13, .closeWindow)), "⌘W is free again")
        XCTAssertNil(reverted.first { $0.action == .splitPaneRight }, "preset chords removed")
    }

    func test_revert_neverRestoresOntoAChordTakenSince() {
        let applied = preset.apply(to: Keybinding.defaults)
        var edited = applied.bindings.filter { !($0.modifierMask == [.command] && $0.keyCode == 13) }
        edited.append(binding([.command], 13, .nextUnreadSession))
        edited.removeAll { $0.action == .nextUnreadSession && $0.keyCode != 13 }

        let reverted = preset.revert(edited, restoring: applied.replaced)

        XCTAssertTrue(reverted.contains(binding([.command], 13, .nextUnreadSession)))
        XCTAssertNil(reverted.first { $0.action == .closeWindow }, "its chord is taken")
    }

    func test_revert_withoutARecord_restoresDefaultsForFreedChords() {
        let applied = preset.apply(to: Keybinding.defaults)

        assertSameBindings(preset.revert(applied.bindings, restoring: Keybinding.defaults), Keybinding.defaults)
    }

    // MARK: summary (Preferences and the tour)

    func test_summaryRows_foldArrowsAndDigits() {
        XCTAssertEqual(preset.summaryRows.map(\.chords), [
            "⌘T", "⌘D", "⇧⌘D", "⌘W", "⇧⌘W", "⇧⌘↩", "⌥⌘←→↑↓", "⌘1…⌘9", "⇧⌘[ ⇧⌘]",
        ])
        XCTAssertEqual(preset.summaryRows.map(\.title), [
            "New Workspace", "Split Pane Right", "Split Pane Down", "Close Pane", "Close Workspace",
            "Zoom Pane", "Focus Pane in Direction", "Go to Workspace 1–9", "Previous / Next Workspace",
        ])
    }

    func test_changeDescriptions_listOnlyWhatGetsDisplaced() {
        let custom = binding([.control, .option], 9, .splitPaneRight)
        XCTAssertEqual(preset.changeDescriptions(from: Keybinding.defaults + [custom]), [
            "Split Pane Right: ⌃⌥V → ⌘D",
            "⌘W: Close Window → Close Pane",
        ])
        XCTAssertEqual(preset.changeDescriptions(from: []), [])
    }
}
