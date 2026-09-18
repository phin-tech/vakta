//
//  SidebarSettings.swift
//  Vakta
//
//  The full persisted state of the sidebar, so it resumes exactly as the user
//  left it across relaunches: its collapse *style* (icon rail vs. hidden),
//  whether it is currently collapsed, and the width it was last expanded to.
//  `AppDelegate` reads all three in `applySidebarWidth` to place the split
//  divider. Persisted as JSON in Application Support.
//
//  The file grew from a bare `SidebarCollapseStyle` string into the
//  `SidebarSettings` struct below; `SidebarSettingsFileCodec` migrates the
//  legacy shape (mirroring `KeybindingFileCodec`) and defaults fields an
//  older or partial file omits.
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

/// Durable sidebar state. `expandedWidth` is stored as-is even when out of a
/// sensible range; it is clamped where it is applied (see `SidebarWidthCapture`
/// / `applySidebarWidth`) rather than at decode time, so a stray value never
/// makes the file undecodable and strands launch.
struct SidebarSettings: Codable, Equatable {
    var collapseStyle: SidebarCollapseStyle
    var isCollapsed: Bool
    var expandedWidth: CGFloat

    /// The full-panel width used before the user has dragged the divider.
    static let defaultExpandedWidth: CGFloat = 220

    init(
        collapseStyle: SidebarCollapseStyle = .icons,
        isCollapsed: Bool = false,
        expandedWidth: CGFloat = SidebarSettings.defaultExpandedWidth
    ) {
        self.collapseStyle = collapseStyle
        self.isCollapsed = isCollapsed
        self.expandedWidth = expandedWidth
    }

    private enum CodingKeys: String, CodingKey {
        case collapseStyle, isCollapsed, expandedWidth
    }

    /// `collapseStyle` is required (an unknown value makes the whole file
    /// undecodable -- the codec then treats it as corrupt and keeps the bytes);
    /// the fields added later default when absent, so a file written before
    /// they existed still decodes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collapseStyle = try container.decode(SidebarCollapseStyle.self, forKey: .collapseStyle)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        expandedWidth = try container.decodeIfPresent(CGFloat.self, forKey: .expandedWidth)
            ?? SidebarSettings.defaultExpandedWidth
    }
}

/// Decodes/migrates the sidebar file for `PersistedFileStore`. Recognizes the
/// current `SidebarSettings` struct and the legacy bare `SidebarCollapseStyle`
/// string written before the struct existed; any other shape (malformed JSON,
/// or an unknown collapse style) is not decodable -- the caller must preserve
/// rather than reinterpret it.
struct SidebarSettingsFileCodec: FilePayloadCodec {
    func decode(_ data: Data) -> SidebarSettings? {
        if let settings = try? JSONDecoder().decode(SidebarSettings.self, from: data) {
            return settings
        }
        // Legacy: a bare collapse-style string written before the struct existed.
        if let legacyStyle = try? JSONDecoder().decode(SidebarCollapseStyle.self, from: data) {
            return SidebarSettings(collapseStyle: legacyStyle)
        }
        return nil
    }

    func encode(_ payload: SidebarSettings) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }
}

enum SidebarSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<SidebarSettingsFileCodec> {
        PersistedFileStore(root: root, fileName: "sidebar.json", codec: SidebarSettingsFileCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<SidebarSettings> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ settings: SidebarSettings, root: URL) -> FileSaveOutcome {
        store(root: root).save(settings)
    }
}

/// Source of truth for the sidebar's collapse style, collapsed state, and
/// expanded width. `AppDelegate` observes `$isCollapsed`/`$collapseStyle` to
/// re-apply the divider width when either changes; every mutation persists the
/// full `SidebarSettings` immediately.
@MainActor
final class SidebarSettingsStore: ObservableObject {
    @Published var collapseStyle: SidebarCollapseStyle {
        didSet { persist() }
    }

    /// Whether the sidebar is collapsed to its rail/hidden state. Toggled by
    /// the sidebar's own button and the View menu; persisted so the sidebar
    /// reopens in the state it was left.
    @Published var isCollapsed: Bool {
        didSet { persist() }
    }

    /// The width to restore the sidebar to when expanded, updated as the user
    /// drags the divider (see `SidebarWidthCapture`).
    @Published var expandedWidth: CGFloat {
        didSet { persist() }
    }

    private let root: URL

    init(root: URL) {
        self.root = root
        // A corrupt/unreadable file falls back to the defaults for this run
        // only -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        let settings: SidebarSettings
        var seedDefaults = false
        switch SidebarSettingsPersistence.load(root: root) {
        case .missing:
            settings = SidebarSettings()
            seedDefaults = true
        case .loaded(let loaded):
            settings = loaded
        case .corrupt, .unreadable:
            settings = SidebarSettings()
        }
        collapseStyle = settings.collapseStyle
        isCollapsed = settings.isCollapsed
        expandedWidth = settings.expandedWidth
        if seedDefaults {
            SidebarSettingsPersistence.save(settings, root: root)
        }
    }

    /// Flips the collapsed state; the `didSet` on `isCollapsed` persists it.
    func toggleCollapsed() {
        isCollapsed.toggle()
    }

    private func persist() {
        SidebarSettingsPersistence.save(
            SidebarSettings(
                collapseStyle: collapseStyle,
                isCollapsed: isCollapsed,
                expandedWidth: expandedWidth
            ),
            root: root
        )
    }
}
