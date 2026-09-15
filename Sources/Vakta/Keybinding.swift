//
//  Keybinding.swift
//  Vakta
//
//  Settled design decision #6: "switch to session N" is not a libghostty
//  action (libghostty has no concept of Vakta's sidebar), so it is never
//  stored in ghostty's config. It lives here, as Vakta's own tiny config
//  type: an exact modifier mask + a physical key code.

import AppKit

/// `Codable` so a future settings screen can persist rebindings (e.g. to
/// `~/Library/Application Support/Vakta/keybindings.json`) — not wired up
/// yet in this skeleton; `KeybindingMatcher.bindings` is in-memory only,
/// seeded from `Keybinding.defaults` on every launch.
/// TODO: load/save this array; nothing currently persists a rebinding.
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

    /// 0-based session index this chord selects.
    var sessionIndex: Int
}

extension Keybinding {
    /// `NSEvent.ModifierFlags` isn't `Codable` (it's a plain `OptionSet`
    /// over a platform-defined raw bit pattern), so `Keybinding` encodes it
    /// as that raw value instead of deriving the conformance.
    private enum CodingKeys: String, CodingKey {
        case modifierMask, keyCode, sessionIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifierMask = NSEvent.ModifierFlags(
            rawValue: try container.decode(UInt.self, forKey: .modifierMask)
        )
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        sessionIndex = try container.decode(Int.self, forKey: .sessionIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modifierMask.rawValue, forKey: .modifierMask)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(sessionIndex, forKey: .sessionIndex)
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

    /// Default bindings: Ctrl+Shift+1 ... Ctrl+Shift+9 select session 0...8.
    static var defaults: [Keybinding] {
        digitKeyCodes.enumerated().map { index, code in
            Keybinding(modifierMask: [.control, .shift], keyCode: code, sessionIndex: index)
        }
    }
}
