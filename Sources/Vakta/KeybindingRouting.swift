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
enum AppCommandScope {
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

extension AppCommand {
    var scope: AppCommandScope {
        switch self {
        case .quit, .closeWindow: return .global
        case .selectSession, .toggleSidebar, .openPreferences, .openSessionSwitcher, .copy, .paste, .cut, .selectAll,
             .increaseFontSize, .decreaseFontSize, .resetFontSize, .nextUnreadSession,
             .newSession, .toggleFileSidebar, .toggleFileSidebarChanges, .openInEditor,
             .showStatusBarBriefly, .cycleStatusBar, .openPullRequest, .showPullRequests,
             .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane,
             .closeWorkspace, .newWorkspace, .stopSession,
             .editHerdrConfig, .reloadHerdrConfig, .focusWorkspace,
             .showWelcomeTour, .showWhatsNew:
            return .contextSensitive
        }
    }
}

enum KeybindingRoutingPlanner {
    /// `true` if a matched `action` should actually be dispatched given
    /// whether the current first responder is a text-editing view.
    static func shouldConsume(action: AppCommand, isTextEntryFocused: Bool) -> Bool {
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
    case drillDown
    case back
    /// Not one of the switcher's navigation keys, or marked text (an
    /// in-progress input-method composition) owns this key instead --
    /// let it reach the search field's field editor normally.
    case passthrough
}

/// A standard text-editing command the switcher's search field should run but
/// that Vakta's ⌘-equivalent-free menu (kept empty so the terminal receives
/// keys) doesn't provide. The panel dispatches these to the field editor
/// directly -- see `SessionSwitcherPanel.performKeyEquivalent`.
enum SwitcherEditingCommand: Equatable {
    case selectAll
    case copy
    case cut
    case paste
}

enum SessionSwitcherKeyRouter {
    private static let moveDownKeyCode: UInt16 = 125
    private static let moveUpKeyCode: UInt16 = 126
    private static let returnKeyCode: UInt16 = 36
    private static let escapeKeyCode: UInt16 = 53
    private static let tabKeyCode: UInt16 = 48

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
    /// switcher's own bare-key nav nor any bound `AppCommand` chord
    /// should shadow the field editor's normal text-editing behavior. The
    /// sole intentional exception is ⇧Tab, which backs out of a palette
    /// scope rather than moving focus to another control.
    static func intent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> SwitcherKeyIntent {
        guard !hasMarkedText else { return .passthrough }
        let relevantModifiers = modifiers.intersection(relevantModifierMask)
        if keyCode == tabKeyCode {
            switch relevantModifiers {
            case []: return .drillDown
            case [.shift]: return .back
            default: return .passthrough
            }
        }
        guard relevantModifiers.isEmpty else { return .passthrough }
        switch keyCode {
        case moveDownKeyCode: return .moveDown
        case moveUpKeyCode: return .moveUp
        case returnKeyCode: return .commit
        case escapeKeyCode: return .cancel
        default: return .passthrough
        }
    }

    /// The standard editing command for a ⌘-chord, matched by the produced
    /// character (layout-independent, unlike a physical key code) so ⌘A means
    /// "select all" wherever the `a` key lives. Only a bare ⌘ counts; any other
    /// modifier (except the Shift that may uppercase the character) or an
    /// in-progress IME composition yields `nil`, letting the field editor keep
    /// the key.
    static func editingCommand(characters: String?, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> SwitcherEditingCommand? {
        guard !hasMarkedText else { return nil }
        guard modifiers.intersection(relevantModifierMask).subtracting(.shift) == [.command] else { return nil }
        switch characters?.lowercased() {
        case "a": return .selectAll
        case "c": return .copy
        case "x": return .cut
        case "v": return .paste
        default: return nil
        }
    }
}
