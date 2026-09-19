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
    private let stores: Stores

    init(stores: Stores) {
        self.stores = stores
    }

    /// Opens the Preferences window, creating it on first use and reusing it
    /// afterward.
    func show(section: PreferencesSection? = nil) {
        stores.preferencesRouter.requested = section
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingView(
            rootView: PreferencesView().environmentStores(stores).environmentObject(stores.herdrConfig)
        )
        let window = PreferencesWindow(
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
        stores.keybindingMatcher.cancelCaptureWhenResigningKey(from: window)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Escape closes Preferences, like a standard macOS preferences/dialog window.
/// `cancelOperation(_:)` only reaches the window when nothing in the responder
/// chain handled Escape first: a text field being edited keeps its own Escape,
/// and a shortcut being recorded is consumed by the keybinding matcher's
/// monitor before any responder sees it.
private final class PreferencesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
