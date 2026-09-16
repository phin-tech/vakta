//
//  KeybindingPersistence.swift
//  Vakta
//
//  Reads/writes the user's keybindings as JSON, so a rebinding survives a
//  restart. Thin wrapper over `PersistedFileStore<KeybindingFileCodec>` (the
//  shared boundary -- see `PersistedFileStore.swift`); the root directory is
//  injected so tests never touch real Application Support.

import Foundation

enum KeybindingPersistence {
    /// Bump when adding a migration in `KeybindingStartupPlanner.plan`.
    /// v2 added the ⌘K switcher; v3 added ⌘Q quit.
    static let currentVersion = 3

    static func store(root: URL) -> PersistedFileStore<KeybindingFileCodec> {
        PersistedFileStore(root: root, fileName: "keybindings.json", codec: KeybindingFileCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<StoredKeybindingsPayload> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ bindings: [Keybinding], root: URL) -> FileSaveOutcome {
        store(root: root).save(StoredKeybindingsPayload(version: currentVersion, bindings: bindings))
    }
}
