//
//  FileSidebarPreferences.swift
//  Vakta
//
//  Whether the right-hand file sidebar (a tree of the focused pane's working
//  directory) is shown, and its width. Off by default -- opt-in, not a
//  surprise on upgrade -- and edited in the Appearance preferences pane.
//  Persisted like the other settings (JSON in Application Support).
//

import Foundation

struct FileSidebarPreferences: Equatable {
    var isVisible: Bool = false
    var width: Double = 260

    /// The width clamped to a sane on-screen range at the point of use, so a
    /// corrupt or extreme persisted value can't produce an unusable pane.
    static let minimumWidth: Double = 160
    static let maximumWidth: Double = 640

    var clampedWidth: Double {
        guard width.isFinite else { return 260 }
        return min(max(width, Self.minimumWidth), Self.maximumWidth)
    }
}

extension FileSidebarPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case isVisible
        case width
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 260
    }
}

enum FileSidebarPreferencesPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<FileSidebarPreferences>> {
        PersistedFileStore(root: root, fileName: "file-sidebar.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<FileSidebarPreferences> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ preferences: FileSidebarPreferences, root: URL) -> FileSaveOutcome {
        store(root: root).save(preferences)
    }
}

/// Source of truth for the file sidebar's visibility and width. The window
/// shows/hides the right pane on `isVisible`; each change is persisted
/// immediately (a corrupt file falls back to defaults for this run only and
/// is not overwritten -- see `PersistedFileStore`).
@MainActor
final class FileSidebarPreferencesStore: ObservableObject {
    @Published var isVisible: Bool { didSet { persist() } }
    @Published var width: Double { didSet { persist() } }

    /// `width` clamped to the on-screen range for laying out the pane.
    var clampedWidth: Double {
        FileSidebarPreferences(isVisible: isVisible, width: width).clampedWidth
    }

    private let root: URL

    init(root: URL) {
        self.root = root
        let outcome = FileSidebarPreferencesPersistence.load(root: root)
        let loaded: FileSidebarPreferences
        switch outcome {
        case .missing: loaded = FileSidebarPreferences()
        case .loaded(let preferences): loaded = preferences
        case .corrupt, .unreadable: loaded = FileSidebarPreferences()
        }
        isVisible = loaded.isVisible
        width = loaded.width

        if case .missing = outcome {
            FileSidebarPreferencesPersistence.save(loaded, root: root)
        }
    }

    private func persist() {
        FileSidebarPreferencesPersistence.save(
            FileSidebarPreferences(isVisible: isVisible, width: width),
            root: root
        )
    }
}
