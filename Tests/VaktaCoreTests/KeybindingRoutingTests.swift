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
        let actions: [KeybindingAction] = [
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
        let actions: [KeybindingAction] = [
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
