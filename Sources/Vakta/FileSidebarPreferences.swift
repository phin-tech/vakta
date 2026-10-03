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

/// What the file sidebar lists: the whole directory tree, only the files
/// with git changes, or an Extension's Panel View.
enum FileSidebarMode: Hashable {
    case files
    case changes
    case extensionView(PanelViewRef)
}

/// One Extension's Panel View: manifest id plus the view's id.
struct PanelViewRef: Hashable {
    var extensionID: String
    var viewID: String
}

/// Persisted as a string: `files`, `changes`, or `extension:<id>/<view>`.
extension FileSidebarMode: Codable {
    private static let extensionPrefix = "extension:"

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        switch text {
        case "files": self = .files
        case "changes": self = .changes
        default:
            guard text.hasPrefix(Self.extensionPrefix) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown mode \(text)"))
            }
            let parts = text.dropFirst(Self.extensionPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "malformed mode \(text)"))
            }
            self = .extensionView(PanelViewRef(extensionID: String(parts[0]), viewID: String(parts[1])))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .files: try container.encode("files")
        case .changes: try container.encode("changes")
        case .extensionView(let ref): try container.encode("\(Self.extensionPrefix)\(ref.extensionID)/\(ref.viewID)")
        }
    }
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
