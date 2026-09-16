//
//  AppearancePersistence.swift
//  Vakta
//
//  Reads/writes the chosen UI-chrome appearance as JSON in Application
//  Support, matching the `ProfilePersistence` pattern -- one atomic file at
//  a stable path. Not yet migrated onto the shared `PersistedFileStore`
//  boundary (see kata k916); `KeybindingPersistence` and
//  `PassthroughSettingsPersistence` are the migrated examples.

import Foundation

enum AppearancePersistence {
    /// `~/Library/Application Support/Vakta/appearance.json`. The directory is
    /// created on demand. Falls back to the temp dir if Application Support
    /// can't be resolved (it always can on macOS, but the API is throwing).
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
        return directory.appendingPathComponent("appearance.json")
    }

    /// The saved settings, or `nil` on first launch / an unreadable file
    /// (treated as first launch so a corrupt file reseeds defaults). Decodes a
    /// legacy bare-`AppAppearance` file too, so upgrading keeps the user's
    /// existing theme and just adds the default sidebar font.
    static func load() -> AppearanceSettings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let settings = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            return settings
        }
        if let legacy = try? JSONDecoder().decode(AppAppearance.self, from: data) {
            return AppearanceSettings(appearance: legacy)
        }
        return nil
    }

    static func save(_ settings: AppearanceSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
