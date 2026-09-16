//
//  KeybindingPersistence.swift
//  Vakta
//
//  Reads/writes the user's keybindings as JSON in Application Support, so a
//  rebinding survives a restart. `Keybinding` is `Codable`, so this is just an
//  atomic file at a stable path -- the same pattern as `ProfilePersistence`.

import Foundation

/// The on-disk shape: a schema version alongside the bindings. Versioning lets
/// one-time migrations (e.g. adding the ⌘K switcher default) run exactly once,
/// so a user who *clears* a migrated binding doesn't have it re-added on every
/// relaunch. A file written before versioning is a bare `[Keybinding]` array
/// and is treated as version 1.
private struct StoredKeybindings: Codable {
    var version: Int
    var bindings: [Keybinding]
}

enum KeybindingPersistence {
    /// Bump when adding a migration in `KeybindingMatcher.init`.
    /// v2 added the ⌘K switcher; v3 added ⌘Q quit.
    static let currentVersion = 3

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

    /// The saved bindings plus the on-disk schema version (1 = a legacy bare
    /// array predating versioning), or `nil` if there's no file yet (first
    /// launch) or it can't be read/decoded (treated as first launch so a
    /// corrupt file reseeds rather than bricking the app).
    static func load() -> (bindings: [Keybinding], version: Int)? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let stored = try? JSONDecoder().decode(StoredKeybindings.self, from: data) {
            return (stored.bindings, stored.version)
        }
        // Legacy: a bare array written before the versioned envelope existed.
        if let legacy = try? JSONDecoder().decode([Keybinding].self, from: data) {
            return (legacy, 1)
        }
        return nil
    }

    static func save(_ bindings: [Keybinding]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = StoredKeybindings(version: currentVersion, bindings: bindings)
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
