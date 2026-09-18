//
//  SidebarRowFontResolver.swift
//  Vakta
//
//  Pure sizing decision for `SidebarView.rowFont`'s terminal-match mode,
//  kept separate from SwiftUI so it's table-driven testable.

import Foundation

enum SidebarRowFontResolver {
    /// The point size sidebar rows should use in terminal-match mode: the
    /// terminal's own font size, validated the same way every other reader
    /// validates it (`TerminalFontSizeValidator`) rather than trusting
    /// `terminalFontSize` is already in range -- it's only guaranteed
    /// validated at `TerminalSettingsStore` load, not on every subsequent
    /// write. Falls back to `fallback` (the sidebar's previous hardcoded
    /// constant) when the terminal is at ghostty's own default (`0`, or an
    /// otherwise invalid value that also validates to `0`), since there is
    /// no numeric default to mirror on the Swift side.
    static func fontSize(matchingTerminal terminalFontSize: Double, fallback: Double = 13) -> Double {
        let effective = TerminalFontSizeValidator.effective(terminalFontSize)
        return effective > 0 ? effective : fallback
    }

    /// The size with the Appearance preference applied: an explicit sidebar
    /// size wins; `0` or an invalid value (validated like the terminal's,
    /// since a hand-edited file can hold anything) follows the terminal.
    static func fontSize(sidebarOverride: Double, matchingTerminal terminalFontSize: Double, fallback: Double = 13) -> Double {
        let explicit = TerminalFontSizeValidator.effective(sidebarOverride)
        return explicit > 0 ? explicit : fontSize(matchingTerminal: terminalFontSize, fallback: fallback)
    }

    /// Whether the user actually chose a sidebar size (valid and non-zero).
    static func hasExplicitSize(_ sidebarOverride: Double) -> Bool {
        TerminalFontSizeValidator.effective(sidebarOverride) > 0
    }
}
