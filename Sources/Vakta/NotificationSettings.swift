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
    /// `~/Library/Application Support/Vakta/notifications.json`.
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
        return directory.appendingPathComponent("notifications.json")
    }

    static func load() -> NotificationSettings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(NotificationSettings.self, from: data)
    }

    static func save(_ settings: NotificationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
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

    init() {
        let loaded = NotificationSettingsPersistence.load() ?? NotificationSettings()
        notifyOnAttention = loaded.notifyOnAttention
        notifyOnFinished = loaded.notifyOnFinished
        bounceDock = loaded.bounceDock
        if NotificationSettingsPersistence.load() == nil {
            NotificationSettingsPersistence.save(loaded)
        }
    }

    private func persist() {
        NotificationSettingsPersistence.save(
            NotificationSettings(
                notifyOnAttention: notifyOnAttention,
                notifyOnFinished: notifyOnFinished,
                bounceDock: bounceDock
            )
        )
    }
}
