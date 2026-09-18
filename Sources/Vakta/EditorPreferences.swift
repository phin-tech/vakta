//
//  EditorPreferences.swift
//  Vakta
//
//  Which editor "Open in Editor" launches. `.auto` (the default) defers to
//  `OpenInEditorPlanner`'s marker/`$EDITOR`/first-installed resolution
//  instead of a fixed choice. JetBrains IDEs are out of scope (per-product
//  bundle IDs, a separate effort). Persisted like the other settings (JSON
//  in Application Support).

import Foundation

enum EditorChoice: String, Codable, CaseIterable, Identifiable, Hashable {
    case auto
    case vscode
    case cursor
    case xcode
    case zed
    case sublimeText
    case bbedit
    case nova
    case textmate

    var id: String { rawValue }

    /// `nil` for `.auto` (no single app to look up) and for a choice whose
    /// bundle identifier turns out to be wrong -- `OpenInEditorPlanner`
    /// treats either the same as "not installed," never crashes.
    var bundleIdentifier: String? {
        switch self {
        case .auto: return nil
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92" // to verify
        case .xcode: return "com.apple.dt.Xcode"
        case .zed: return "dev.zed.Zed"
        case .sublimeText: return "com.sublimetext.4" // to verify
        case .bbedit: return "com.barebones.bbedit" // to verify
        case .nova: return "com.panic.Nova" // to verify
        case .textmate: return "com.macromates.TextMate" // to verify
        }
    }

    /// Display name for the Preferences picker. Not core-tested -- a UI
    /// string, same as `AppAppearance.title`/`SidebarFontMode.title`.
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .xcode: return "Xcode"
        case .zed: return "Zed"
        case .sublimeText: return "Sublime Text"
        case .bbedit: return "BBEdit"
        case .nova: return "Nova"
        case .textmate: return "TextMate"
        }
    }

    /// Maps a bare `$EDITOR`/`$VISUAL` command name (not a full path) to the
    /// editor it launches, for `OpenInEditorPlanner`'s auto resolution.
    /// `nil` for a command this feature doesn't recognize (e.g. `vim`).
    init?(commandName: String) {
        switch commandName {
        case "code": self = .vscode
        case "cursor": self = .cursor
        case "zed": self = .zed
        case "subl": self = .sublimeText
        case "bbedit": self = .bbedit
        default: return nil
        }
    }
}

struct EditorPreferences: Equatable {
    var choice: EditorChoice = .auto
}

extension EditorPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case choice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choice = try container.decodeIfPresent(EditorChoice.self, forKey: .choice) ?? .auto
    }
}

enum EditorPreferencesPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<EditorPreferences>> {
        PersistedFileStore(root: root, fileName: "editor.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<EditorPreferences> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ preferences: EditorPreferences, root: URL) -> FileSaveOutcome {
        store(root: root).save(preferences)
    }
}

/// Source of truth for the editor preference. The preferences pane edits
/// `choice`, and each change is persisted immediately.
@MainActor
final class EditorPreferencesStore: ObservableObject {
    @Published var choice: EditorChoice { didSet { persist() } }

    private let root: URL

    init(root: URL) {
        self.root = root
        // A corrupt/unreadable file falls back to defaults for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        let outcome = EditorPreferencesPersistence.load(root: root)
        let loaded: EditorPreferences
        switch outcome {
        case .missing: loaded = EditorPreferences()
        case .loaded(let preferences): loaded = preferences
        case .corrupt, .unreadable: loaded = EditorPreferences()
        }
        choice = loaded.choice

        if case .missing = outcome {
            EditorPreferencesPersistence.save(loaded, root: root)
        }
    }

    private func persist() {
        EditorPreferencesPersistence.save(EditorPreferences(choice: choice), root: root)
    }
}
