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
