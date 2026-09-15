//
//  KeybindingPersistence.swift
//  Vakta
//
//  Reads/writes the user's keybindings as JSON in Application Support, so a
//  rebinding survives a restart. `Keybinding` is `Codable`, so this is just an
//  atomic file at a stable path -- the same pattern as `ProfilePersistence`.

import Foundation

enum KeybindingPersistence {
    /// `~/Library/Application Support/Vakta/keybindings.json`. The directory is
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
        return directory.appendingPathComponent("keybindings.json")
    }

    /// The saved bindings, or `nil` if there's no file yet (first launch) or
    /// it can't be read/decoded (treated as first launch so a corrupt file
    /// reseeds rather than bricking the app).
    static func load() -> [Keybinding]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([Keybinding].self, from: data)
    }

    static func save(_ bindings: [Keybinding]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bindings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
