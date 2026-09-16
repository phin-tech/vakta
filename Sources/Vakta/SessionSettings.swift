//
//  SessionSettings.swift
//  Vakta
//
//  Session-related preferences that aren't the profiles themselves. Currently
//  just the default profile a plain "New Session" uses (the sidebar `+`, the
//  menu's "New Session", and the ⌘-chord-less quick create). Persisted like the
//  other settings; `SessionStore` reads it to resolve `defaultProfile`.

import Foundation

enum SessionSettingsPersistence {
    struct Payload: Codable, Equatable {
        var defaultProfileID: UUID?
    }

    static func store(root: URL) -> PersistedFileStore<JSONCodec<Payload>> {
        PersistedFileStore(root: root, fileName: "session.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<Payload> {
        store(root: root).load()
    }

    @discardableResult
    static func saveDefaultProfileID(_ id: UUID?, root: URL) -> FileSaveOutcome {
        store(root: root).save(Payload(defaultProfileID: id))
    }
}
