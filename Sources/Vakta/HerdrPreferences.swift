//
//  HerdrPreferences.swift
//  Vakta
//
//  Whether a herdr session row in the sidebar can be expanded to show (and
//  switch to) its workspaces. Off by default -- opt-in, not a surprise on
//  upgrade. Persisted like the other settings (JSON in Application Support),
//  edited in the "Herdr" preferences pane.

import Foundation

struct HerdrPreferences: Equatable {
    var showWorkspaces: Bool = false
}

extension HerdrPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case showWorkspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .showWorkspaces) ?? false
    }
}

enum HerdrPreferencesPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<HerdrPreferences>> {
        PersistedFileStore(root: root, fileName: "herdr.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<HerdrPreferences> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ preferences: HerdrPreferences, root: URL) -> FileSaveOutcome {
        store(root: root).save(preferences)
    }
}

/// Source of truth for herdr preferences. The sidebar's per-session
/// disclosure reads `showWorkspaces` to decide whether to offer expansion at
/// all; the preferences pane edits it and each change is persisted
/// immediately.
@MainActor
final class HerdrPreferencesStore: ObservableObject {
    @Published var showWorkspaces: Bool { didSet { persist() } }

    private let root: URL

    init(root: URL) {
        self.root = root
        // A corrupt/unreadable file falls back to defaults for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        let outcome = HerdrPreferencesPersistence.load(root: root)
        let loaded: HerdrPreferences
        switch outcome {
        case .missing: loaded = HerdrPreferences()
        case .loaded(let preferences): loaded = preferences
        case .corrupt, .unreadable: loaded = HerdrPreferences()
        }
        showWorkspaces = loaded.showWorkspaces

        if case .missing = outcome {
            HerdrPreferencesPersistence.save(loaded, root: root)
        }
    }

    private func persist() {
        HerdrPreferencesPersistence.save(HerdrPreferences(showWorkspaces: showWorkspaces), root: root)
    }
}
