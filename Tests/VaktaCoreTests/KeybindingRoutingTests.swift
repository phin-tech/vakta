//
//  KeybindingRoutingTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `KeybindingRoutingPlanner` and
//  `SessionSwitcherKeyRouter`: pure decisions from action/keyCode + context
//  values, with no NSEvent, NSResponder, or window involved.

import AppKit
import XCTest
@testable import Vakta

final class KeybindingRoutingPlannerTests: XCTestCase {
    func test_globalAction_quit_consumesEvenWhenTextEntryFocused() {
        XCTAssertTrue(KeybindingRoutingPlanner.shouldConsume(action: .quit, isTextEntryFocused: true))
        XCTAssertTrue(KeybindingRoutingPlanner.shouldConsume(action: .quit, isTextEntryFocused: false))
    }

    func test_contextSensitiveAction_consumesWhenNoTextEntryIsFocused() {
        let actions: [AppCommand] = [
            .selectSession(0), .toggleSidebar, .openPreferences, .openSessionSwitcher
        ]
        for action in actions {
            XCTAssertTrue(
                KeybindingRoutingPlanner.shouldConsume(action: action, isTextEntryFocused: false),
                "\(action) should consume when nothing is editing text"
            )
        }
    }

    func test_contextSensitiveAction_fallsThroughWhenTextEntryFocused() {
        let actions: [AppCommand] = [
            .selectSession(3), .toggleSidebar, .openPreferences, .openSessionSwitcher
        ]
        for action in actions {
            XCTAssertFalse(
                KeybindingRoutingPlanner.shouldConsume(action: action, isTextEntryFocused: true),
                "\(action) must fall through to normal text editing (paste/undo/select-all/...) " +
                "when a text field is being edited"
            )
        }
    }
}

extension KeybindingRoutingPlannerTests {
    /// Commands the registry added from the ⌘K palette: all ordinary app
    /// commands, so a text field keeps its normal meaning for the chord.
    func test_registryAddedCommands_areContextSensitive() {
        let added: [AppCommand] = [
            .newSession, .toggleFileSidebar, .openInEditor,
            .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane,
            .closeWorkspace, .newWorkspace, .stopSession,
            .editHerdrConfig, .reloadHerdrConfig, .focusWorkspace(0),
        ]
        for command in added {
            XCTAssertTrue(KeybindingRoutingPlanner.shouldConsume(action: command, isTextEntryFocused: false), "\(command)")
            XCTAssertFalse(KeybindingRoutingPlanner.shouldConsume(action: command, isTextEntryFocused: true), "\(command)")
        }
    }

    func test_quitAndCloseWindow_remainGlobal() {
        for command: AppCommand in [.quit, .closeWindow] {
            XCTAssertEqual(command.scope, .global, "\(command)")
        }
    }
}

final class SessionSwitcherKeyRouterTests: XCTestCase {
    func test_downArrow_noMarkedText_noModifiers_isMoveDown() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 125, modifiers: [], hasMarkedText: false), .moveDown)
    }

    func test_upArrow_noMarkedText_noModifiers_isMoveUp() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 126, modifiers: [], hasMarkedText: false), .moveUp)
    }

    func test_return_noMarkedText_noModifiers_isCommit() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 36, modifiers: [], hasMarkedText: false), .commit)
    }

    func test_escape_noMarkedText_noModifiers_isCancel() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 53, modifiers: [], hasMarkedText: false), .cancel)
    }

    func test_tab_noMarkedText_noModifiers_isDrillDown() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 48, modifiers: [], hasMarkedText: false), .drillDown)
    }

    func test_shiftTab_noMarkedText_isBack() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 48, modifiers: .shift, hasMarkedText: false), .back)
    }

    func test_tab_withMarkedText_isPassthroughToTheIMECandidateWindow() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 48, modifiers: [], hasMarkedText: true), .passthrough)
    }

    func test_tab_withCommandOrOption_isPassthroughToTheFieldEditor() {
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 48, modifiers: .command, hasMarkedText: false), .passthrough)
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 48, modifiers: .option, hasMarkedText: false), .passthrough)
    }

    func test_typingKey_isPassthrough() {
        // 'a' -- not one of the four navigation keys, always falls through
        // to the search field regardless of marked text.
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 0, modifiers: [], hasMarkedText: false), .passthrough)
        XCTAssertEqual(SessionSwitcherKeyRouter.intent(keyCode: 0, modifiers: [], hasMarkedText: true), .passthrough)
    }

    func test_navigationKeys_withMarkedText_arePassthroughToTheIMECandidateWindow() {
        // An in-progress input-method composition uses these same four keys
        // to operate on ITS OWN candidate list/confirmation, not the
        // switcher's session list.
        for keyCode: UInt16 in [125, 126, 36, 53] {
            XCTAssertEqual(
                SessionSwitcherKeyRouter.intent(keyCode: keyCode, modifiers: [], hasMarkedText: true),
                .passthrough,
                "keyCode \(keyCode) must reach the field editor while marked text is active"
            )
        }
    }

    // MARK: editingCommand -- ⌘A/⌘C/⌘X/⌘V for the search field, which Vakta's
    // ⌘-equivalent-free menu doesn't otherwise provide.

    func test_commandA_isSelectAll() {
        XCTAssertEqual(
            SessionSwitcherKeyRouter.editingCommand(characters: "a", modifiers: .command, hasMarkedText: false),
            .selectAll
        )
    }

    func test_commandCXV_mapToClipboardCommands() {
        XCTAssertEqual(SessionSwitcherKeyRouter.editingCommand(characters: "c", modifiers: .command, hasMarkedText: false), .copy)
        XCTAssertEqual(SessionSwitcherKeyRouter.editingCommand(characters: "x", modifiers: .command, hasMarkedText: false), .cut)
        XCTAssertEqual(SessionSwitcherKeyRouter.editingCommand(characters: "v", modifiers: .command, hasMarkedText: false), .paste)
    }

    func test_commandA_uppercaseCharacters_stillSelectAll() {
        // charactersIgnoringModifiers can arrive uppercased when Shift/CapsLock
        // is involved; match case-insensitively.
        XCTAssertEqual(
            SessionSwitcherKeyRouter.editingCommand(characters: "A", modifiers: [.command, .shift], hasMarkedText: false),
            .selectAll
        )
    }

    func test_commandA_withMarkedText_isNil_soTheIMEKeepsTheKey() {
        XCTAssertNil(SessionSwitcherKeyRouter.editingCommand(characters: "a", modifiers: .command, hasMarkedText: true))
    }

    func test_bareA_orOtherModifier_isNotAnEditingCommand() {
        XCTAssertNil(SessionSwitcherKeyRouter.editingCommand(characters: "a", modifiers: [], hasMarkedText: false))
        XCTAssertNil(SessionSwitcherKeyRouter.editingCommand(characters: "a", modifiers: .control, hasMarkedText: false))
        XCTAssertNil(SessionSwitcherKeyRouter.editingCommand(characters: "b", modifiers: .command, hasMarkedText: false))
        XCTAssertNil(SessionSwitcherKeyRouter.editingCommand(characters: nil, modifiers: .command, hasMarkedText: false))
    }

    func test_navigationKeys_withAHeldModifier_arePassthroughToTheFieldEditor() {
        // ⇧↑/⇧↓ extend the search field's text selection, ⌘↑/⌘↓ jump to its
        // start/end, ⌥⏎ is a text-editing convention elsewhere -- none of
        // these should be reinterpreted as bare switcher navigation.
        let cases: [(UInt16, NSEvent.ModifierFlags)] = [
            (125, .shift), (126, .shift), (125, .command), (36, .option)
        ]
        for (keyCode, modifiers) in cases {
            XCTAssertEqual(
                SessionSwitcherKeyRouter.intent(keyCode: keyCode, modifiers: modifiers, hasMarkedText: false),
                .passthrough,
                "keyCode \(keyCode) with modifiers \(modifiers) must fall through, not move/commit/cancel"
            )
        }
    }

    func test_downArrow_deviceFlagsWithNoRealModifier_stillMovesDown() {
        // Real arrow-key events carry `.numericPad`/`.function` in
        // `modifierFlags` even with no user-held modifier -- these must not
        // themselves count as "a modifier is held."
        let deviceFlagsOnly: NSEvent.ModifierFlags = [.numericPad, .function]
        XCTAssertEqual(
            SessionSwitcherKeyRouter.intent(keyCode: 125, modifiers: deviceFlagsOnly, hasMarkedText: false),
            .moveDown
        )
    }
}
