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
}
