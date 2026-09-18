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
    let keybindingMatcher: KeybindingMatcher
    let appearanceStore: AppearanceStore
    let sidebarSettings: SidebarSettingsStore
    let notificationSettings: NotificationSettingsStore
    let unreadTrackingSettings: UnreadTrackingSettingsStore
    let terminalSettings: TerminalSettingsStore
    let herdrPreferences: HerdrPreferencesStore
    let editorPreferences: EditorPreferencesStore
    let sessionStore: SessionStore
    let workspaceRefreshMonitor: WorkspaceRefreshMonitor
    let persistenceFailures = PersistenceFailureCenter()

    /// `root` is resolved once by the caller (`AppDelegate`, which can fail
    /// launch cleanly if it throws) and threaded through every store here,
    /// rather than each store resolving -- and creating -- Application
    /// Support independently. `resolvedPATH` is likewise created by the
    /// caller as early in launch as possible, so its background shell
    /// resolution has the maximum head start before `SessionStore` needs it.
    init(root: URL, resolvedPATH: ResolvedPATH) {
        keybindingMatcher = KeybindingMatcher(root: root)
        appearanceStore = AppearanceStore(root: root)
        sidebarSettings = SidebarSettingsStore(root: root)
        notificationSettings = NotificationSettingsStore(root: root)
        unreadTrackingSettings = UnreadTrackingSettingsStore(root: root)
        terminalSettings = TerminalSettingsStore(root: root)
        herdrPreferences = HerdrPreferencesStore(root: root)
        editorPreferences = EditorPreferencesStore(root: root)
        // `sessionStore` needs `terminalSettings`/`unreadTrackingSettings`
        // (already initialized above).
        sessionStore = SessionStore(
            terminalSettings: terminalSettings,
            unreadTrackingSettings: unreadTrackingSettings,
            root: root,
            pathResolver: resolvedPATH
        )
        workspaceRefreshMonitor = WorkspaceRefreshMonitor(sessionStore: sessionStore, herdrPreferences: herdrPreferences)
    }
}

extension View {
    /// Injects every app store into the environment in one call.
    func environmentStores(_ stores: Stores) -> some View {
        environmentObject(stores.keybindingMatcher)
            .environmentObject(stores.appearanceStore)
            .environmentObject(stores.sidebarSettings)
            .environmentObject(stores.notificationSettings)
            .environmentObject(stores.unreadTrackingSettings)
            .environmentObject(stores.terminalSettings)
            .environmentObject(stores.herdrPreferences)
            .environmentObject(stores.editorPreferences)
            .environmentObject(stores.sessionStore)
            .environmentObject(stores.sessionStore.notifier)
            .environmentObject(stores.persistenceFailures)
    }
}
