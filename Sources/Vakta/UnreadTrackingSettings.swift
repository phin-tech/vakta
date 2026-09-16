//
//  UnreadTrackingSettings.swift
//  Vakta
//
//  Which AgentStatus transitions populate the sidebar bell popover (see
//  `UnreadAttentionPolicy`/`SessionStore.unreadPanes`). Deliberately its own
//  settings type, not folded into `NotificationSettings`: the bell is
//  independent of whether OS banners/Dock bouncing are enabled (see
//  `UnreadAttentionPolicy`'s doc comment) -- a user might want the in-app
//  bell to track `.working` starts, say, without ever wanting a banner for
//  every one of those. Persisted like the other settings (JSON in
//  Application Support), edited in the "Notifications" preferences pane.

import Foundation

/// The persisted payload. A plain `Codable` snapshot the store reads/writes.
struct UnreadTrackingSettings: Codable, Equatable {
    /// Track a session/workspace becoming `.attention` (needs input).
    var trackAttention: Bool = true
    /// Track a session/workspace becoming `.done` (finished a task).
    var trackDone: Bool = true
    /// Track a session/workspace starting `.working`.
    var trackWorking: Bool = false
    /// Track a session/workspace going `.idle`.
    var trackIdle: Bool = false

    /// The set `UnreadAttentionPolicy.shouldMarkUnread` checks `to` against.
    var trackedStatuses: Set<AgentStatus> {
        var statuses: Set<AgentStatus> = []
        if trackAttention { statuses.insert(.attention) }
        if trackDone { statuses.insert(.done) }
        if trackWorking { statuses.insert(.working) }
        if trackIdle { statuses.insert(.idle) }
        return statuses
    }
}

enum UnreadTrackingSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<UnreadTrackingSettings>> {
        PersistedFileStore(root: root, fileName: "unread-tracking.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<UnreadTrackingSettings> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ settings: UnreadTrackingSettings, root: URL) -> FileSaveOutcome {
        store(root: root).save(settings)
    }
}

/// Source of truth for which statuses populate the bell. `SessionStore`
/// reads `trackedStatuses` on each poll; the preferences pane edits the four
/// flags and each change is persisted immediately.
@MainActor
final class UnreadTrackingSettingsStore: ObservableObject {
    @Published var trackAttention: Bool { didSet { persist() } }
    @Published var trackDone: Bool { didSet { persist() } }
    @Published var trackWorking: Bool { didSet { persist() } }
    @Published var trackIdle: Bool { didSet { persist() } }

    private let root: URL

    var trackedStatuses: Set<AgentStatus> {
        UnreadTrackingSettings(
            trackAttention: trackAttention,
            trackDone: trackDone,
            trackWorking: trackWorking,
            trackIdle: trackIdle
        ).trackedStatuses
    }

    init(root: URL) {
        self.root = root
        // A corrupt/unreadable file falls back to defaults for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        let outcome = UnreadTrackingSettingsPersistence.load(root: root)
        let loaded: UnreadTrackingSettings
        switch outcome {
        case .missing: loaded = UnreadTrackingSettings()
        case .loaded(let settings): loaded = settings
        case .corrupt, .unreadable: loaded = UnreadTrackingSettings()
        }
        trackAttention = loaded.trackAttention
        trackDone = loaded.trackDone
        trackWorking = loaded.trackWorking
        trackIdle = loaded.trackIdle

        if case .missing = outcome {
            UnreadTrackingSettingsPersistence.save(loaded, root: root)
        }
    }

    private func persist() {
        UnreadTrackingSettingsPersistence.save(
            UnreadTrackingSettings(
                trackAttention: trackAttention,
                trackDone: trackDone,
                trackWorking: trackWorking,
                trackIdle: trackIdle
            ),
            root: root
        )
    }
}
