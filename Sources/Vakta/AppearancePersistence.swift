//
//  AppearancePersistence.swift
//  Vakta
//
//  Reads/writes the chosen UI-chrome appearance as JSON in Application
//  Support, matching the `ProfilePersistence` / `KeybindingPersistence`
//  pattern -- one atomic file at a stable path.

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

    /// The saved appearance, or `nil` on first launch / an unreadable file
    /// (treated as first launch so a corrupt file reseeds `.system`).
    static func load() -> AppAppearance? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AppAppearance.self, from: data)
    }

    static func save(_ appearance: AppAppearance) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
