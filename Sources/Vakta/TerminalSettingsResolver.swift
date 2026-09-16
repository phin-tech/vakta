//
//  TerminalSettingsResolver.swift
//  Vakta
//
//  Pure validation/resolution for persisted `TerminalSettings`, kept
//  separate from view rendering and controller mutation. `TerminalSettings`
//  uses synthesized `Codable` with no range validation, so a malformed or
//  hand-edited `terminal.json` can decode a `fontSize` that's negative,
//  non-finite (`NaN`/`infinity`), or absurdly large -- previously
//  `TerminalPreferencesView` converted it straight to `Int`, which TRAPS for
//  a non-finite or out-of-`Int`-range `Double`, and `SessionStore` sent it
//  to libghostty as raw config text unvalidated either way.

import Foundation
import GhosttyTheme

enum TerminalFontSizeValidator {
    /// The usable font-size range. Chosen generously (way past any font a
    /// terminal is actually usable at) rather than tightly, since the goal
    /// is rejecting corrupt/extreme values, not opinion about house style.
    static let validRange: ClosedRange<Double> = 1...200

    /// `size` if finite and within `validRange`, else `0` -- "use ghostty's
    /// default," the same sentinel `TerminalSettings.fontSize`'s own doc
    /// comment already defines for "no explicit size." Callers that convert
    /// to `Int` for display, or that build libghostty config text, must
    /// always go through this first.
    static func effective(_ size: Double) -> Double {
        guard size.isFinite, validRange.contains(size) else { return 0 }
        return size
    }
}

enum TerminalThemeResolver {
    /// Mirrors `SessionStore.applyThemeColors`'s neutral fallback colors as
    /// hex strings, used only if even the built-in default theme name (see
    /// `TerminalSettings.defaultThemeName`) somehow fails to resolve --
    /// unreachable in practice, since that name is itself drawn from the
    /// same compiled-in `GhosttyThemeCatalog`, but `resolve` must still
    /// never be partial.
    static let ultimateFallback = GhosttyThemeDefinition(
        name: "Vakta Fallback",
        background: "1E1E24",
        foreground: "FFFFFF",
        selectionBackground: "454859",
        palette: [4: "5A5FBF"]
    )

    /// The theme definition actually used for `themeName`: the named theme
    /// if the catalog has it, else the built-in default's definition, else
    /// `ultimateFallback`. ONE resolution, used for both the terminal
    /// (`.toTerminalTheme()`) and the derived sidebar colors
    /// (`SessionStore.applyThemeColors`) -- previously an unknown theme name
    /// resolved differently at launch (`TerminalTheme.default`, paired with
    /// neutral-fallback sidebar colors -- already two different sources)
    /// versus on a live change (the terminal silently kept its OLD theme
    /// while the sidebar switched to the neutral fallback anyway), so
    /// terminal and chrome could visibly disagree either way.
    static func resolve(themeName: String) -> GhosttyThemeDefinition {
        GhosttyThemeCatalog.theme(named: themeName)
            ?? GhosttyThemeCatalog.theme(named: TerminalSettings.defaultThemeName)
            ?? ultimateFallback
    }
}
