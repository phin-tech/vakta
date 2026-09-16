//
//  WorkspacePersistence.swift
//  Vakta
//
//  Persists the set of open sessions so relaunching Vakta reopens them. Each
//  record is just enough to recreate a session and have it reconnect: which
//  profile, the multiplexer session name to attach-or-create, and any user
//  rename. The live terminal isn't saved -- herdr/tmux keep the real session
//  alive server-side, and the record is what lets Vakta re-attach to it.

import Foundation

/// One persisted open session.
struct SessionRecord: Codable, Hashable {
    /// The profile to recreate the session from. If it no longer exists on
    /// restore, `SessionStore` falls back to the default profile.
    var profileID: Profile.ID
    /// The multiplexer session name (`{name}`), stable across restarts.
    var sessionName: String
    /// The user's rename, if any.
    var customName: String?
}

enum WorkspacePersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<[SessionRecord]>> {
        PersistedFileStore(root: root, fileName: "workspace.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<[SessionRecord]> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ records: [SessionRecord], root: URL) -> FileSaveOutcome {
        store(root: root).save(records)
    }
}
