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

/// What the file sidebar lists: the whole directory tree, or only the files
/// with git changes.
enum FileSidebarMode: String, Codable {
    case files
    case changes
}

struct FileSidebarPreferences: Equatable {
    var isVisible: Bool = false
    var width: Double = 260
    var mode: FileSidebarMode = .files

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
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 260
        // An unknown mode (a newer build's) is a view preference, not data
        // worth rejecting the file over: fall back to the tree.
        mode = (try? container.decodeIfPresent(FileSidebarMode.self, forKey: .mode)) ?? .files
    }
}

enum FileSidebarModePlanner {
    /// The "Toggle File Sidebar Git Changes" command: a hidden sidebar opens
    /// straight into Changes; a visible one flips between Files and Changes
    /// and stays open (Toggle File Sidebar is what hides it).
    static func togglingChanges(_ preferences: FileSidebarPreferences) -> FileSidebarPreferences {
        var next = preferences
        if !preferences.isVisible {
            next.isVisible = true
            next.mode = .changes
        } else {
            next.mode = preferences.mode == .changes ? .files : .changes
        }
        return next
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
    @Published var mode: FileSidebarMode { didSet { persist() } }

    var preferences: FileSidebarPreferences {
        FileSidebarPreferences(isVisible: isVisible, width: width, mode: mode)
    }

    /// `width` clamped to the on-screen range for laying out the pane.
    var clampedWidth: Double { preferences.clampedWidth }

    private var isApplying = false

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
        mode = loaded.mode

        if case .missing = outcome {
            FileSidebarPreferencesPersistence.save(loaded, root: root)
        }
    }

    /// Sets every field from `preferences`, saving once at the end rather
    /// than once per changed field.
    func apply(_ preferences: FileSidebarPreferences) {
        isApplying = true
        if mode != preferences.mode { mode = preferences.mode }
        if width != preferences.width { width = preferences.width }
        if isVisible != preferences.isVisible { isVisible = preferences.isVisible }
        isApplying = false
        persist()
    }

    private func persist() {
        guard !isApplying else { return }
        FileSidebarPreferencesPersistence.save(preferences, root: root)
    }
}
