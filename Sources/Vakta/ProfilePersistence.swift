//
//  ProfilePersistence.swift
//  Vakta
//
//  Reads/writes the user's profiles through `PersistedFileStore` (the shared
//  boundary -- see `PersistedFileStore.swift`), so edits, new profiles, and
//  deletions survive a restart. The root is injected so tests never touch
//  real Application Support.

import Foundation

enum ProfilePersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<[Profile]>> {
        PersistedFileStore(root: root, fileName: "profiles.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<[Profile]> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ profiles: [Profile], root: URL) -> FileSaveOutcome {
        store(root: root).save(profiles)
    }
}
