//
//  MenuBarSettings.swift
//  Vakta
//
//  Where Vakta shows its agent-status item outside the window: the macOS
//  menu bar (on by default) and SketchyBar (off by default). Each is
//  toggled independently in Preferences.
//

import Foundation

struct MenuBarSettings: Equatable {
    var showsMenuBarItem = true
    var showsSketchyBarItem = false
}

extension MenuBarSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case showsMenuBarItem
        case showsSketchyBarItem
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsMenuBarItem = try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarItem) ?? true
        showsSketchyBarItem = try container.decodeIfPresent(Bool.self, forKey: .showsSketchyBarItem) ?? false
    }
}

enum MenuBarSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<MenuBarSettings>> {
        PersistedFileStore(root: root, fileName: "menu-bar.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<MenuBarSettings> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ settings: MenuBarSettings, root: URL) -> FileSaveOutcome {
        store(root: root).save(settings)
    }
}

/// Source of truth for both toggles; each change is persisted immediately.
@MainActor
final class MenuBarSettingsStore: ObservableObject {
    @Published var showsMenuBarItem: Bool { didSet { persist() } }
    @Published var showsSketchyBarItem: Bool { didSet { persist() } }
    /// Why the SketchyBar item couldn't be drawn, for Preferences; nil when
    /// it was (or is off). Set by `AppDelegate`; never persisted.
    @Published var sketchyBarProblem: String?

    private let root: URL

    init(root: URL) {
        self.root = root
        // A corrupt/unreadable file falls back to defaults for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        let outcome = MenuBarSettingsPersistence.load(root: root)
        let loaded: MenuBarSettings
        switch outcome {
        case .loaded(let settings): loaded = settings
        case .missing, .corrupt, .unreadable: loaded = MenuBarSettings()
        }
        showsMenuBarItem = loaded.showsMenuBarItem
        showsSketchyBarItem = loaded.showsSketchyBarItem

        if case .missing = outcome {
            MenuBarSettingsPersistence.save(loaded, root: root)
        }
    }

    private func persist() {
        MenuBarSettingsPersistence.save(
            MenuBarSettings(showsMenuBarItem: showsMenuBarItem, showsSketchyBarItem: showsSketchyBarItem),
            root: root
        )
    }
}
