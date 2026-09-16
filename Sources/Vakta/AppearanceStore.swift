//
//  AppearanceStore.swift
//  Vakta
//
//  Single source of truth for the UI-chrome appearance. An `ObservableObject`
//  so the Preferences pane edits it directly; every change persists and is
//  applied to `NSApp.appearance` live (all non-terminal windows follow it).

import AppKit

@MainActor
final class AppearanceStore: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet {
            persist()
            apply()
        }
    }

    /// Whether the sidebar's session rows use the system font or the terminal
    /// font. Read by `SidebarView`.
    @Published var sidebarFont: SidebarFontMode {
        didSet { persist() }
    }

    init() {
        // Load saved choice; first launch (or an unreadable file) seeds
        // defaults and writes them. Assigning in init does not fire `didSet`,
        // so `AppDelegate` calls `apply()` once after launch.
        let loaded = AppearancePersistence.load()
        appearance = loaded?.appearance ?? .system
        sidebarFont = loaded?.sidebarFont ?? .system
        if loaded == nil {
            AppearancePersistence.save(AppearanceSettings())
        }
    }

    private func persist() {
        AppearancePersistence.save(
            AppearanceSettings(appearance: appearance, sidebarFont: sidebarFont)
        )
    }

    /// Pushes the current choice onto `NSApp`. `nil` (System) hands control
    /// back to the OS setting.
    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }
}
