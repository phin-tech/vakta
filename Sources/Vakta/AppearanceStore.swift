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
            AppearancePersistence.save(appearance)
            apply()
        }
    }

    init() {
        // Load saved choice; first launch (or an unreadable file) seeds
        // `.system` and writes it. Assigning in init does not fire `didSet`,
        // so `AppDelegate` calls `apply()` once after launch.
        let loaded = AppearancePersistence.load()
        appearance = loaded ?? .system
        if loaded == nil {
            AppearancePersistence.save(.system)
        }
    }

    /// Pushes the current choice onto `NSApp`. `nil` (System) hands control
    /// back to the OS setting.
    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }
}
