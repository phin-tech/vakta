//
//  TerminalSettings.swift
//  Vakta
//
//  User-chosen terminal font and theme, applied to every libghostty surface
//  via the single shared `TerminalController` (see `SessionStore`). Changes
//  apply live -- the controller reconfigures in place -- so there's no restart.
//
//  An empty `fontFamily` / zero `fontSize` means "ghostty's default": the
//  corresponding config key is simply omitted rather than sent blank.

import Foundation

/// The persisted `terminal.json` payload.
struct TerminalSettings: Codable, Equatable {
    /// Font family name (e.g. "SF Mono"). Empty = ghostty default.
    var fontFamily: String = ""
    /// Point size. 0 = ghostty default.
    var fontSize: Double = 0
    /// A `GhosttyThemeCatalog` theme name.
    var themeName: String = "Dracula"
}

enum TerminalSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<TerminalSettings>> {
        PersistedFileStore(root: root, fileName: "terminal.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<TerminalSettings> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ settings: TerminalSettings, root: URL) -> FileSaveOutcome {
        store(root: root).save(settings)
    }
}

/// Source of truth for terminal font + theme. `SessionStore` reads it at launch
/// and observes it, pushing changes to the shared controller live.
@MainActor
final class TerminalSettingsStore: ObservableObject {
    @Published var fontFamily: String { didSet { persist() } }
    @Published var fontSize: Double { didSet { persist() } }
    @Published var themeName: String { didSet { persist() } }

    private let root: URL

    init(root: URL = ApplicationSupportRoot.resolve()) {
        self.root = root
        // A corrupt/unreadable file falls back to defaults for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        let outcome = TerminalSettingsPersistence.load(root: root)
        let loaded: TerminalSettings
        switch outcome {
        case .missing: loaded = TerminalSettings()
        case .loaded(let settings): loaded = settings
        case .corrupt, .unreadable: loaded = TerminalSettings()
        }
        fontFamily = loaded.fontFamily
        fontSize = loaded.fontSize
        themeName = loaded.themeName

        if case .missing = outcome {
            TerminalSettingsPersistence.save(loaded, root: root)
        }
    }

    var snapshot: TerminalSettings {
        TerminalSettings(fontFamily: fontFamily, fontSize: fontSize, themeName: themeName)
    }

    private func persist() {
        TerminalSettingsPersistence.save(snapshot, root: root)
    }
}
