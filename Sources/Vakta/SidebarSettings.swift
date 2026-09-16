//
//  SidebarSettings.swift
//  Vakta
//
//  How the sidebar behaves when collapsed: shrunk to an icon rail, or hidden
//  entirely. `AppDelegate` reads this in `applySidebarWidth` to choose the
//  collapsed divider position (a narrow rail vs. zero width). Persisted like
//  the other settings (JSON in Application Support).
//
//  Note: when "Hidden" is chosen the sidebar's own toggle button vanishes with
//  it, so the sidebar is brought back via the View menu's "Toggle Sidebar" (or
//  a chord bound to it in Keybindings), not a click.

import AppKit

/// What "collapsed" means for the sidebar.
enum SidebarCollapseStyle: String, Codable, CaseIterable, Identifiable {
    /// A narrow rail of session icons (the original behavior).
    case icons
    /// No sidebar at all.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icons: return "Icons"
        case .hidden: return "Hidden"
        }
    }
}

enum SidebarSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<SidebarCollapseStyle>> {
        PersistedFileStore(root: root, fileName: "sidebar.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<SidebarCollapseStyle> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ style: SidebarCollapseStyle, root: URL) -> FileSaveOutcome {
        store(root: root).save(style)
    }
}

/// Source of truth for the sidebar collapse style. `AppDelegate` observes
/// `collapseStyle` to re-apply the sidebar width when it changes.
@MainActor
final class SidebarSettingsStore: ObservableObject {
    @Published var collapseStyle: SidebarCollapseStyle {
        didSet { SidebarSettingsPersistence.save(collapseStyle, root: root) }
    }

    private let root: URL

    init(root: URL = ApplicationSupportRoot.resolve()) {
        self.root = root
        // A corrupt/unreadable file falls back to `.icons` for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        switch SidebarSettingsPersistence.load(root: root) {
        case .missing:
            collapseStyle = .icons
            SidebarSettingsPersistence.save(.icons, root: root)
        case .loaded(let style):
            collapseStyle = style
        case .corrupt, .unreadable:
            collapseStyle = .icons
        }
    }
}
