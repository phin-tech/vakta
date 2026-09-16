//
//  PreferencesWindowController.swift
//  Vakta
//
//  A single, reused Preferences window. There is no SwiftUI `Settings` scene
//  to hook into (Vakta runs a plain `NSApplication`, see `App.swift`), so this
//  is a hand-built `NSWindow` hosting the SwiftUI `PreferencesView` via
//  `NSHostingView`. `AppDelegate` holds one instance and calls `show()`; a
//  second "Open Preferences" just refocuses the existing window.

import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController {
    private var window: NSWindow?
    private let keybindingMatcher: KeybindingMatcher
    private let appearanceStore: AppearanceStore
    private let sidebarSettings: SidebarSettingsStore
    private let notificationSettings: NotificationSettingsStore
    private let terminalSettings: TerminalSettingsStore

    init(
        keybindingMatcher: KeybindingMatcher,
        appearanceStore: AppearanceStore,
        sidebarSettings: SidebarSettingsStore,
        notificationSettings: NotificationSettingsStore,
        terminalSettings: TerminalSettingsStore
    ) {
        self.keybindingMatcher = keybindingMatcher
        self.appearanceStore = appearanceStore
        self.sidebarSettings = sidebarSettings
        self.notificationSettings = notificationSettings
        self.terminalSettings = terminalSettings
    }

    /// Opens the Preferences window, creating it on first use and reusing it
    /// afterward.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingView(
            rootView: PreferencesView()
                .environmentObject(keybindingMatcher)
                .environmentObject(appearanceStore)
                .environmentObject(sidebarSettings)
                .environmentObject(notificationSettings)
                .environmentObject(terminalSettings)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.contentView = host
        window.setContentSize(NSSize(width: 640, height: 420))
        window.contentMinSize = NSSize(width: 520, height: 320)
        window.center()
        // Like the main window: hold it with a strong Swift reference and stop
        // AppKit additionally releasing it on close, which would over-release
        // and crash the next time it's shown.
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
