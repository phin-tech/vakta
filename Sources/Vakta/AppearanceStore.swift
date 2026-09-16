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

    private let root: URL

    init(root: URL) {
        self.root = root
        // Load saved choice; first launch seeds defaults and writes them. A
        // corrupt/unreadable file falls back to defaults for this run only
        // -- it is deliberately NOT overwritten (see `PersistedFileStore`).
        // Assigning in init does not fire `didSet`, so `AppDelegate` calls
        // `apply()` once after launch.
        let outcome = AppearancePersistence.load(root: root)
        let loaded: AppearanceSettings
        switch outcome {
        case .missing: loaded = AppearanceSettings()
        case .loaded(let settings): loaded = settings
        case .corrupt, .unreadable: loaded = AppearanceSettings()
        }
        appearance = loaded.appearance
        sidebarFont = loaded.sidebarFont

        if case .missing = outcome {
            AppearancePersistence.save(loaded, root: root)
        }
    }

    private func persist() {
        AppearancePersistence.save(
            AppearanceSettings(appearance: appearance, sidebarFont: sidebarFont),
            root: root
        )
    }

    /// Pushes the current choice onto `NSApp`. `nil` (System) hands control
    /// back to the OS setting.
    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }
}
