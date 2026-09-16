//
//  TerminalSettings.swift
//  Vakta
//
//  User-chosen terminal font and theme, applied to every libghostty surface
//  via the single shared `TerminalController` (see `SessionStore`). Changes
//  apply live -- the controller reconfigures in place -- so there's no restart.
//
//  An empty `fontFamily` / zero `fontSize` means "ghostty's default": the
//  corresponding config key is simply omitted rather than sent blank.

import Foundation

/// The persisted `terminal.json` payload.
struct TerminalSettings: Codable, Equatable {
    /// Font family name (e.g. "SF Mono"). Empty = ghostty default.
    var fontFamily: String = ""
    /// Point size. 0 = ghostty default.
    var fontSize: Double = 0
    /// A `GhosttyThemeCatalog` theme name.
    var themeName: String = "Dracula"
}

enum TerminalSettingsPersistence {
    /// `~/Library/Application Support/Vakta/terminal.json`.
    static var fileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let directory = base.appendingPathComponent("Vakta", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("terminal.json")
    }

    static func load() -> TerminalSettings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TerminalSettings.self, from: data)
    }

    static func save(_ settings: TerminalSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Source of truth for terminal font + theme. `SessionStore` reads it at launch
/// and observes it, pushing changes to the shared controller live.
@MainActor
final class TerminalSettingsStore: ObservableObject {
    @Published var fontFamily: String { didSet { persist() } }
    @Published var fontSize: Double { didSet { persist() } }
    @Published var themeName: String { didSet { persist() } }

    init() {
        let loaded = TerminalSettingsPersistence.load() ?? TerminalSettings()
        fontFamily = loaded.fontFamily
        fontSize = loaded.fontSize
        themeName = loaded.themeName
        if TerminalSettingsPersistence.load() == nil {
            TerminalSettingsPersistence.save(loaded)
        }
    }

    var snapshot: TerminalSettings {
        TerminalSettings(fontFamily: fontFamily, fontSize: fontSize, themeName: themeName)
    }

    private func persist() {
        TerminalSettingsPersistence.save(snapshot)
    }
}
