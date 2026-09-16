//
//  KeybindingRouting.swift
//  Vakta
//
//  Pure decision rules for whether a matched keybinding should actually fire,
//  and for what a session-switcher navigation key means -- kept separate from
//  `KeybindingMatcher`'s AppKit event monitor and `SessionSwitcherPanel`'s
//  `sendEvent` override so both can be tested as input/output without a real
//  window or first responder.

import AppKit

/// Whether an action should fire everywhere (even while a text field owns
/// first responder) or only when nothing is actively editing text.
enum KeybindingActionScope {
    /// Always fires. Reserved for actions a user must always be able to
    /// reach, however they got into whatever state they're in.
    case global
    /// Only fires when the current first responder isn't a text-editing
    /// view -- otherwise the chord's normal text-editing meaning (paste,
    /// undo, select-all, ...) wins, since KeybindingMatcher's monitor runs
    /// in front of every window, including Preferences and the profile
    /// editor, and a user-recorded chord only has to collide with one
    /// single-modifier editing shortcut to make this observable.
    case contextSensitive
}

extension KeybindingAction {
    var scope: KeybindingActionScope {
        switch self {
        case .quit, .closeWindow: return .global
        case .selectSession, .toggleSidebar, .openPreferences, .openSessionSwitcher, .copy, .paste, .cut, .selectAll,
             .increaseFontSize, .decreaseFontSize, .resetFontSize, .nextUnreadSession:
            return .contextSensitive
        }
    }
}

enum KeybindingRoutingPlanner {
    /// `true` if a matched `action` should actually be dispatched given
    /// whether the current first responder is a text-editing view.
    static func shouldConsume(action: KeybindingAction, isTextEntryFocused: Bool) -> Bool {
        switch action.scope {
        case .global: return true
        case .contextSensitive: return !isTextEntryFocused
        }
    }
}

/// What a key the session switcher's panel intercepts should do.
enum SwitcherKeyIntent: Equatable {
    case moveDown
    case moveUp
    case commit
    case cancel
    /// Not one of the switcher's navigation keys, or marked text (an
    /// in-progress input-method composition) owns this key instead --
    /// let it reach the search field's field editor normally.
    case passthrough
}

enum SessionSwitcherKeyRouter {
    private static let moveDownKeyCode: UInt16 = 125
    private static let moveUpKeyCode: UInt16 = 126
    private static let returnKeyCode: UInt16 = 36
    private static let escapeKeyCode: UInt16 = 53

    /// The subset of `NSEvent.modifierFlags` relevant to distinguishing a
    /// modified chord from a bare navigation key. Callers must intersect
    /// `event.modifierFlags` against this before calling `intent` -- arrow
    /// keys otherwise carry device flags (`.numericPad`, `.function`) that
    /// would make even a bare ↓ look "modified."
    static let relevantModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// `hasMarkedText` takes priority over every navigation key: an IME
    /// candidate window uses these same keys (arrows to move the highlighted
    /// candidate, Return to confirm, Escape to cancel composition) to
    /// operate on the marked text itself, not the switcher's own list.
    ///
    /// A held modifier also always falls through -- ⇧↑/⇧↓ extend the search
    /// field's text selection, ⌘↑/⌘↓ jump to its start/end, and neither the
    /// switcher's own bare-key nav nor any bound `KeybindingAction` chord
    /// should shadow the field editor's normal text-editing behavior.
    static func intent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> SwitcherKeyIntent {
        guard !hasMarkedText, modifiers.intersection(relevantModifierMask).isEmpty else { return .passthrough }
        switch keyCode {
        case moveDownKeyCode: return .moveDown
        case moveUpKeyCode: return .moveUp
        case returnKeyCode: return .commit
        case escapeKeyCode: return .cancel
        default: return .passthrough
        }
    }
}
