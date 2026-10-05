//
//  StatusBar.swift
//  Vakta
//
//  The status bar under the terminal: its visibility preference and the pure
//  decisions for what it shows. Vakta draws no content of its own -- every
//  segment comes from an Extension's Status Item (pull request status is
//  the GitHub Built-in Extension) -- and nothing renders without data.
//

import Foundation

enum StatusBarVisibility: String, Codable, CaseIterable {
    /// Docked only while there is something to show.
    case auto
    /// Hidden until hovered at the terminal's bottom edge (Dock-style);
    /// overlays the terminal, so it never resizes it.
    case autoHide
    /// Always docked, empty or not.
    case show
    /// Never shown.
    case hide

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .autoHide: return "Auto-hide"
        case .show: return "Always"
        case .hide: return "Never"
        }
    }

    /// The "Cycle Status Bar Visibility" command's order.
    var next: StatusBarVisibility {
        switch self {
        case .auto: return .autoHide
        case .autoHide: return .show
        case .show: return .hide
        case .hide: return .auto
        }
    }
}

struct StatusBarPreferences: Equatable {
    var visibility: StatusBarVisibility = .auto
}

extension StatusBarPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case visibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown mode (a newer build's) is a view preference, not data
        // worth rejecting the file over.
        visibility = (try? container.decodeIfPresent(StatusBarVisibility.self, forKey: .visibility)) ?? .auto
    }
}

enum StatusBarPreferencesPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<StatusBarPreferences>> {
        PersistedFileStore(root: root, fileName: "status-bar.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<StatusBarPreferences> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ preferences: StatusBarPreferences, root: URL) -> FileSaveOutcome {
        store(root: root).save(preferences)
    }
}

/// Source of truth for the status bar's visibility; each change is persisted
/// immediately (a corrupt file falls back to the default for this run only
/// and is not overwritten -- see `PersistedFileStore`).
@MainActor
final class StatusBarPreferencesStore: ObservableObject {
    @Published var visibility: StatusBarVisibility { didSet { persist() } }

    private let root: URL

    init(root: URL) {
        self.root = root
        let outcome = StatusBarPreferencesPersistence.load(root: root)
        switch outcome {
        case .loaded(let preferences): visibility = preferences.visibility
        case .missing, .corrupt, .unreadable: visibility = StatusBarPreferences().visibility
        }
        if case .missing = outcome {
            persist()
        }
    }

    func cycle() {
        visibility = visibility.next
    }

    private func persist() {
        StatusBarPreferencesPersistence.save(StatusBarPreferences(visibility: visibility), root: root)
    }
}

struct StatusBarContent: Equatable {
    /// Extension Status Items in link order.
    var extensionItems: [StatusBarExtensionItem] = []

    var isEmpty: Bool { extensionItems.isEmpty }
}

enum StatusBarPresentation {
    /// Whether the bar takes space under the terminal. Auto-hide never docks:
    /// it overlays the terminal while revealed.
    static func isDocked(_ visibility: StatusBarVisibility, content: StatusBarContent) -> Bool {
        switch visibility {
        case .show: return true
        case .hide, .autoHide: return false
        case .auto: return !content.isEmpty
        }
    }
}

/// Keys a status bar list takes: Escape closes any open list; the arrows and
/// Return drive a pinned one. Anything with a command-style modifier passes
/// through, so app shortcuts keep working.
enum StatusBarListAction: Equatable {
    case up
    case down
    case open
    case close
}

enum StatusBarListKey {
    static func action(keyCode: UInt16, hasModifiers: Bool) -> StatusBarListAction? {
        guard !hasModifiers else { return nil }
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .open
        case 53: return .close
        default: return nil
        }
    }

    /// Moves the selection by `delta`, starting from the first (down) or
    /// last (up) row when nothing is selected; clamped, nil when empty.
    static func moved(_ selection: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selection else { return delta >= 0 ? 0 : count - 1 }
        return min(max(selection + delta, 0), count - 1)
    }
}
