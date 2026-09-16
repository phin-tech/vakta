//
//  NotificationSettings.swift
//  Vakta
//
//  Whether (and when) Vakta posts a native notification / bounces the Dock as
//  a session's agent status changes. Read by `AttentionNotifier` on each
//  observed transition. Persisted like the other settings (JSON in Application
//  Support), edited in the "Notifications" preferences pane.
//
//  Note: notification *banners* only work when Vakta runs as a real `.app`
//  (it needs a bundle identifier for `UNUserNotificationCenter`). Under a bare
//  `swift run` binary there is no bundle id, so `AttentionNotifier` silently
//  skips banners and the Dock-bounce path still works.

import Foundation

/// The persisted payload. A plain `Codable` snapshot the store reads/writes.
struct NotificationSettings: Codable, Equatable {
    /// Notify when a session's agent starts needing input/attention.
    var notifyOnAttention: Bool = true
    /// Notify when a session's agent finishes (working → idle).
    var notifyOnFinished: Bool = true
    /// Bounce the Dock icon (`requestUserAttention`) on a needs-attention event.
    var bounceDock: Bool = true
}

enum NotificationSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<NotificationSettings>> {
        PersistedFileStore(root: root, fileName: "notifications.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<NotificationSettings> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ settings: NotificationSettings, root: URL) -> FileSaveOutcome {
        store(root: root).save(settings)
    }
}

/// Source of truth for notification preferences. `AttentionNotifier` reads the
/// three flags on each status transition; the preferences pane edits them and
/// each change is persisted immediately.
@MainActor
final class NotificationSettingsStore: ObservableObject {
    @Published var notifyOnAttention: Bool { didSet { persist() } }
    @Published var notifyOnFinished: Bool { didSet { persist() } }
    @Published var bounceDock: Bool { didSet { persist() } }

    private let root: URL

    init(root: URL = ApplicationSupportRoot.resolve()) {
        self.root = root
        // A corrupt/unreadable file falls back to defaults for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        let outcome = NotificationSettingsPersistence.load(root: root)
        let loaded: NotificationSettings
        switch outcome {
        case .missing: loaded = NotificationSettings()
        case .loaded(let settings): loaded = settings
        case .corrupt, .unreadable: loaded = NotificationSettings()
        }
        notifyOnAttention = loaded.notifyOnAttention
        notifyOnFinished = loaded.notifyOnFinished
        bounceDock = loaded.bounceDock

        if case .missing = outcome {
            NotificationSettingsPersistence.save(loaded, root: root)
        }
    }

    private func persist() {
        NotificationSettingsPersistence.save(
            NotificationSettings(
                notifyOnAttention: notifyOnAttention,
                notifyOnFinished: notifyOnFinished,
                bounceDock: bounceDock
            ),
            root: root
        )
    }
}
