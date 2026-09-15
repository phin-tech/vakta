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
    /// `~/Library/Application Support/Vakta/sidebar.json`.
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
        return directory.appendingPathComponent("sidebar.json")
    }

    static func load() -> SidebarCollapseStyle? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SidebarCollapseStyle.self, from: data)
    }

    static func save(_ style: SidebarCollapseStyle) {
        guard let data = try? JSONEncoder().encode(style) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Source of truth for the sidebar collapse style. `AppDelegate` observes
/// `collapseStyle` to re-apply the sidebar width when it changes.
@MainActor
final class SidebarSettingsStore: ObservableObject {
    @Published var collapseStyle: SidebarCollapseStyle {
        didSet { SidebarSettingsPersistence.save(collapseStyle) }
    }

    init() {
        let loaded = SidebarSettingsPersistence.load()
        collapseStyle = loaded ?? .icons
        if loaded == nil {
            SidebarSettingsPersistence.save(.icons)
        }
    }
}
