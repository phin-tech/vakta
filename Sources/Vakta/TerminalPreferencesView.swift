//
//  TerminalPreferencesView.swift
//  Vakta
//
//  The "Terminal" preferences pane: the font and color theme every libghostty
//  surface uses. Changes apply live via `TerminalSettingsStore` ->
//  `SessionStore` -> the shared controller. The sidebar can be told to match
//  this font under Appearance.

import AppKit
import GhosttyTheme
import SwiftUI

struct TerminalPreferencesView: View {
    @EnvironmentObject private var settings: TerminalSettingsStore
    @State private var themeQuery = ""

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $settings.fontFamily) {
                    Text("Default").tag("")
                    ForEach(Self.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                // 0 means "ghostty default" (omitted from config). Step past the
                // unusable 1-8pt range so Default sits next to a readable size.
                Stepper {
                    Text(settings.fontSize > 0
                        ? "Size: \(Int(settings.fontSize)) pt"
                        : "Size: Default")
                } onIncrement: {
                    settings.fontSize = settings.fontSize < 9 ? 9 : min(32, settings.fontSize + 1)
                } onDecrement: {
                    settings.fontSize = settings.fontSize <= 9 ? 0 : settings.fontSize - 1
                }
            }

            Section {
                TextField("Search themes", text: $themeQuery)
                    .textFieldStyle(.roundedBorder)
                Picker("Theme", selection: $settings.themeName) {
                    ForEach(themeChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Theme")
            } footer: {
                Text("Font and theme apply to every terminal immediately. Turn on "
                    + "“Match Terminal” under Appearance to use this font in the "
                    + "sidebar too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The theme names offered in the picker: all of them, or the search
    /// matches, always including the current selection so the picker can render
    /// it even when it's filtered out.
    private var themeChoices: [String] {
        let query = themeQuery.trimmingCharacters(in: .whitespaces)
        var names = query.isEmpty
            ? GhosttyThemeCatalog.allThemes.map(\.name)
            : GhosttyThemeCatalog.search(query).map(\.name)
        if !names.contains(settings.themeName) {
            names.insert(settings.themeName, at: 0)
        }
        return names
    }

    /// Monospaced font families available on this Mac, so the terminal font
    /// picker only offers fonts that make sense for a terminal. Resolves each
    /// family through its first member's PostScript name -- `NSFont(name:)` on a
    /// display family name returns nil for many fonts.
    static let monospacedFamilies: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies
            .filter { family in
                guard
                    let member = manager.availableMembers(ofFontFamily: family)?.first,
                    let psName = member.first as? String,
                    let font = NSFont(name: psName, size: 12)
                else { return false }
                return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
            .sorted()
    }()
}
