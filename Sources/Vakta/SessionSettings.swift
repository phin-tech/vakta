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
    /// `~/Library/Application Support/Vakta/session.json`.
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
        return directory.appendingPathComponent("session.json")
    }

    private struct Payload: Codable {
        var defaultProfileID: UUID?
    }

    /// The chosen default profile id, or nil (use the first profile) if unset
    /// or unreadable.
    static func loadDefaultProfileID() -> UUID? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.defaultProfileID
    }

    static func saveDefaultProfileID(_ id: UUID?) {
        guard let data = try? JSONEncoder().encode(Payload(defaultProfileID: id)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
