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
        return directory.appendingPathComponent("workspace.json")
    }

    /// The saved open-session records, or `nil` on first launch / unreadable
    /// file (treated as "no saved workspace").
    static func load() -> [SessionRecord]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([SessionRecord].self, from: data)
    }

    static func save(_ records: [SessionRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
