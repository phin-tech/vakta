//
//  Appearance.swift
//  Vakta
//
//  The app's UI-chrome appearance: the AppKit/SwiftUI window, sidebar, and
//  Preferences panels -- NOT the terminal, which libghostty renders with its
//  own Metal theme independent of `NSAppearance`. Switching this sets
//  `NSApp.appearance`, which every non-terminal view follows.

import AppKit

/// A user-selectable chrome appearance. `system` defers to the OS setting.
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The `NSAppearance` to apply, or `nil` to follow the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The font the sidebar's session rows use: the system font, or the terminal's
/// font (see `TerminalSettingsStore`) so the sidebar reads like the terminal.
enum SidebarFontMode: String, Codable, CaseIterable, Identifiable {
    case system
    case matchTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .matchTerminal: return "Terminal Style"
        }
    }
}

/// The persisted `appearance.json` payload. A struct (rather than the bare
/// `AppAppearance` enum it used to be) so it can carry the sidebar font mode
/// too; `AppearancePersistence` still decodes the old bare-enum file.
struct AppearanceSettings: Codable, Equatable {
    var appearance: AppAppearance = .system
    var sidebarFont: SidebarFontMode = .system
}
