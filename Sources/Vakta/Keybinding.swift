//
//  Keybinding.swift
//  Vakta
//
//  Vakta's app-level actions (switch to session N, toggle the sidebar, open
//  Preferences) are not libghostty actions (libghostty has no concept of
//  Vakta's sidebar or windows), so they are never stored in ghostty's
//  config. They live here, as Vakta's own tiny config type: an exact
//  modifier mask + a physical key code -> an action (see docs/architecture.md's
//  "The matcher runs in front of every surface" invariant).
//
//  This is also the ONLY path by which those actions can get a keyboard
//  shortcut: docs/architecture.md's "Keybindings routed through the
//  matcher, not menu key equivalents" invariant keeps every menu item free
//  of a `keyEquivalent` so keystrokes reach herdr, so the menu can't carry
//  ⌘-keys. `KeybindingMatcher` intercepts these chords before the surface
//  sees them.

import AppKit

/// What a chord does when matched. `Codable` (synthesized) so bindings
/// persist across launches (see `KeybindingPersistence`).
enum KeybindingAction: Hashable, Codable {
    /// Select the sidebar session at this 0-based index.
    case selectSession(Int)
    /// Collapse/expand the sidebar.
    case toggleSidebar
    /// Open the Preferences window.
    case openPreferences
    /// Open the ⌘K session switcher (command palette).
    case openSessionSwitcher
    /// Quit Vakta.
    case quit
    /// Copy the terminal's current selection to the pasteboard (or the
    /// field editor's selection, when a text field is focused -- see
    /// `KeybindingActionScope.contextSensitive`).
    case copy
    /// Paste the pasteboard's contents into the terminal (or a focused
    /// text field).
    case paste
    /// Standard Edit-menu cut. The terminal surface has no editable text
    /// to cut, so on the terminal this is a no-op; a focused text field
    /// cuts normally.
    case cut
    /// Select the terminal's entire scrollback (or a focused text field's
    /// contents).
    case selectAll
    /// Close the frontmost window. A normal, user-clearable binding like
    /// every other action -- some users route this chord to a terminal
    /// multiplexer running *inside* the session instead (e.g. closing a
    /// pane), and clear this binding so the keystroke reaches the terminal.
    case closeWindow
    /// Grow the terminal's font size (Ghostty's `increase_font_size` binding
    /// action on the selected session's surface).
    case increaseFontSize
    /// Shrink the terminal's font size (`decrease_font_size`).
    case decreaseFontSize
    /// Reset the terminal's font size to the configured default
    /// (`reset_font_size`).
    case resetFontSize

    /// A human label for the Preferences list.
    var title: String {
        switch self {
        case .selectSession(let index): return "Select Session \(index + 1)"
        case .toggleSidebar: return "Toggle Sidebar"
        case .openPreferences: return "Open Preferences"
        case .openSessionSwitcher: return "Session Switcher"
        case .quit: return "Quit"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .cut: return "Cut"
        case .selectAll: return "Select All"
        case .closeWindow: return "Close Window"
        case .increaseFontSize: return "Increase Font Size"
        case .decreaseFontSize: return "Decrease Font Size"
        case .resetFontSize: return "Reset Font Size"
        }
    }
}

/// A modifier mask + physical key code bound to a `KeybindingAction`.
struct Keybinding: Equatable, Codable {
    /// Required modifiers, compared for exact equality (not "at least
    /// these") against the event's modifier flags after masking down to
    /// `[.control, .option, .shift, .command]`. Hyper is simply
    /// `[.control, .option, .shift, .command]` together -- there is no
    /// dedicated `.hyper` case anywhere in this type; representing it as
    /// "all four" is the entire point of using a plain `NSEvent.ModifierFlags`
    /// mask instead of an enum.
    var modifierMask: NSEvent.ModifierFlags

    /// A physical (position-based) key code -- `NSEvent.keyCode`, i.e. the
    /// same underlying HIToolbox virtual key code libghostty itself keys
    /// its own bindings on. Deliberately not a `Character`: a layout-based
    /// binding would silently move (or vanish) when the user switches
    /// keyboard layouts, and the physical key is what most terminal-chord
    /// conventions (tmux, this one included) actually mean by "the 1 key".
    var keyCode: UInt16

    /// What this chord does.
    var action: KeybindingAction
}

extension Keybinding {
    /// `NSEvent.ModifierFlags` isn't `Codable` (it's a plain `OptionSet`
    /// over a platform-defined raw bit pattern), so `Keybinding` encodes it
    /// as that raw value instead of deriving the conformance.
    private enum CodingKeys: String, CodingKey {
        case modifierMask, keyCode, action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifierMask = NSEvent.ModifierFlags(
            rawValue: try container.decode(UInt.self, forKey: .modifierMask)
        )
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        action = try container.decode(KeybindingAction.self, forKey: .action)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modifierMask.rawValue, forKey: .modifierMask)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(action, forKey: .action)
    }

    /// `kVK_ANSI_1` ... `kVK_ANSI_9`, in that order. These are stable,
    /// publicly documented platform constants (Carbon `HIToolbox/Events.h`,
    /// unchanged since classic Mac OS) -- not part of libghostty's unstable
    /// API surface, so they're hardcoded here rather than resolved from the
    /// resolved package checkout the way everything ghostty-related in this
    /// project was.
    ///
    /// TODO(verify): these are physical ANSI-layout codes. On a non-ANSI
    /// (e.g. ISO/JIS) keyboard the digit row is laid out the same way in
    /// practice, but this has not been verified on real non-US hardware.
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25] // 1,2,3,4,5,6,7,8,9

    /// `kVK_ANSI_K` -- the "K" in the default ⌘K session-switcher chord.
    static let kKeyCode: UInt16 = 40
    /// `kVK_ANSI_Q` -- the "Q" in the default ⌘Q quit chord.
    static let qKeyCode: UInt16 = 12
    /// `kVK_ANSI_C` -- the "C" in the default ⌘C copy chord.
    static let cKeyCode: UInt16 = 8
    /// `kVK_ANSI_V` -- the "V" in the default ⌘V paste chord.
    static let vKeyCode: UInt16 = 9
    /// `kVK_ANSI_X` -- the "X" in the default ⌘X cut chord.
    static let xKeyCode: UInt16 = 7
    /// `kVK_ANSI_A` -- the "A" in the default ⌘A select-all chord.
    static let aKeyCode: UInt16 = 0
    /// `kVK_ANSI_W` -- the "W" in the default ⌘W close-window chord.
    static let wKeyCode: UInt16 = 13
    /// `kVK_ANSI_Equal` -- the "=" in the default ⌘= increase-font-size chord.
    static let equalKeyCode: UInt16 = 24
    /// `kVK_ANSI_Minus` -- the "-" in the default ⌘- decrease-font-size chord.
    static let minusKeyCode: UInt16 = 27
    /// `kVK_ANSI_0` -- the "0" in the default ⌘0 reset-font-size chord.
    static let zeroKeyCode: UInt16 = 29

    /// Default bindings: Ctrl+Shift+1 ... Ctrl+Shift+9 select session 0...8,
    /// ⌘K opens the session switcher, ⌘Q quits, ⌘C/⌘V/⌘X are the standard
    /// macOS copy/paste/cut chords, ⌘A selects all, ⌘W closes the front
    /// window, and ⌘=/⌘-/⌘0 zoom the terminal font size (Terminal.app's own
    /// convention). `toggleSidebar` and `openPreferences` ship unbound
    /// (absent from the array); the Preferences pane lets the user assign,
    /// reassign, or clear any of these -- including ⌘W, for a user who wants
    /// that chord to reach a terminal multiplexer running inside the session
    /// instead. Note that a bound chord is consumed before it reaches herdr
    /// (docs/architecture.md's "The matcher runs in front of every surface"
    /// invariant) -- clear the binding to hand that key back to the terminal.
    static var defaults: [Keybinding] {
        var bindings = digitKeyCodes.enumerated().map { index, code in
            Keybinding(modifierMask: [.control, .shift], keyCode: code, action: .selectSession(index))
        }
        bindings.append(Keybinding(modifierMask: [.command], keyCode: kKeyCode, action: .openSessionSwitcher))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: qKeyCode, action: .quit))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: cKeyCode, action: .copy))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: vKeyCode, action: .paste))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: xKeyCode, action: .cut))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: aKeyCode, action: .selectAll))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: wKeyCode, action: .closeWindow))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: equalKeyCode, action: .increaseFontSize))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: minusKeyCode, action: .decreaseFontSize))
        bindings.append(Keybinding(modifierMask: [.command], keyCode: zeroKeyCode, action: .resetFontSize))
        return bindings
    }

    /// A `⌃⌥⇧⌘`-style rendering of the chord for the Preferences list, e.g.
    /// `⌃⇧1`. Modifier glyphs are in Apple's canonical menu order.
    var displayString: String {
        var result = ""
        if modifierMask.contains(.control) { result += "⌃" }
        if modifierMask.contains(.option) { result += "⌥" }
        if modifierMask.contains(.shift) { result += "⇧" }
        if modifierMask.contains(.command) { result += "⌘" }
        result += Self.keyGlyph(for: keyCode)
        return result
    }

    /// A best-effort printable glyph for a physical key code. This is a
    /// static ANSI-US table, not a live layout query (which would need
    /// `UCKeyTranslate`/Carbon): sufficient for v1's default digit chords and
    /// anything a user records on a US layout; a non-US layout may show the
    /// wrong letter glyph even though matching still works on the physical
    /// key. Unknown codes render as `key <code>`.
    static func keyGlyph(for keyCode: UInt16) -> String {
        if let named = namedKeys[keyCode] { return named }
        if let ansi = ansiKeys[keyCode] { return ansi }
        return "key \(keyCode)"
    }

    /// Physical key code -> ANSI-US character.
    private static let ansiKeys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// Physical key code -> a symbol for non-printing keys.
    private static let namedKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
