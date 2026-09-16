//
//  Stores.swift
//  Vakta
//
//  One owner for the app's observable stores, so `AppDelegate` and the
//  Preferences window pass a single value around instead of a growing list of
//  parameters and `.environmentObject(...)` calls. Views still read each store
//  by type via `@EnvironmentObject` (SwiftUI observes per-type); this only
//  bundles construction and injection.

import SwiftUI

@MainActor
final class Stores {
    let keybindingMatcher = KeybindingMatcher()
    let appearanceStore = AppearanceStore()
    let sidebarSettings = SidebarSettingsStore()
    let notificationSettings = NotificationSettingsStore()
    let terminalSettings = TerminalSettingsStore()
    let sessionStore: SessionStore

    init() {
        // `sessionStore` needs `terminalSettings` (already initialized above).
        sessionStore = SessionStore(terminalSettings: terminalSettings)
    }
}

extension View {
    /// Injects every app store into the environment in one call.
    func environmentStores(_ stores: Stores) -> some View {
        environmentObject(stores.keybindingMatcher)
            .environmentObject(stores.appearanceStore)
            .environmentObject(stores.sidebarSettings)
            .environmentObject(stores.notificationSettings)
            .environmentObject(stores.terminalSettings)
            .environmentObject(stores.sessionStore)
    }
}
