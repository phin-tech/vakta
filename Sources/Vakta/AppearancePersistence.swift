//
//  AppearancePersistence.swift
//  Vakta
//
//  Reads/writes the chosen UI-chrome appearance through `PersistedFileStore`
//  (the shared boundary -- see `PersistedFileStore.swift`), with an injected
//  root so tests never touch real Application Support.

import Foundation

/// Decodes/migrates the appearance file: the current `AppearanceSettings`
/// shape, or a legacy bare-`AppAppearance` file (predating `sidebarFont`),
/// so upgrading keeps the user's existing theme and adds the default sidebar
/// font. Any other shape (malformed JSON, or one neither decoder recognizes)
/// is not decodable -- the caller must preserve rather than reinterpret it.
struct AppearanceFileCodec: FilePayloadCodec {
    func decode(_ data: Data) -> AppearanceSettings? {
        if let settings = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            return settings
        }
        if let legacy = try? JSONDecoder().decode(AppAppearance.self, from: data) {
            return AppearanceSettings(appearance: legacy)
        }
        return nil
    }

    func encode(_ payload: AppearanceSettings) -> Data? {
        try? JSONEncoder().encode(payload)
    }
}

enum AppearancePersistence {
    static func store(root: URL) -> PersistedFileStore<AppearanceFileCodec> {
        PersistedFileStore(root: root, fileName: "appearance.json", codec: AppearanceFileCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<AppearanceSettings> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ settings: AppearanceSettings, root: URL) -> FileSaveOutcome {
        store(root: root).save(settings)
    }
}
