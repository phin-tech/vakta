//
//  App.swift
//  Vakta
//
//  Bootstraps a plain `NSApplication` (no storyboard, no Info.plist -- this
//  is the "compiling foundation" the task asks for; an Xcode project /
//  proper .app bundle can come later, see README.md).
//
//  The window's content view is a raw `NSSplitView`: `SidebarView` (SwiftUI,
//  hosted via `NSHostingView`) on the left, `SessionStore.hostContainer`
//  (plain AppKit, owns every session's live surface) on the right, as
//  direct siblings. SwiftUI therefore never owns, wraps, or is asked to
//  diff the terminal container at all -- see `TerminalContainer.swift` for
//  why that matters for settled design decision #4.

import AppKit
import Metal
import SwiftUI

@main
enum VaktaMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let sessionStore = SessionStore()
    private let keybindingMatcher = KeybindingMatcher()

    func applicationDidFinishLaunching(_: Notification) {
        // libghostty renders every surface with Metal and dereferences its
        // rendering context without a nil check, so `ghostty_surface_new`
        // segfaults when there is no usable GPU/window-server context. That
        // happens when Vakta is launched from an SSH session or otherwise with
        // no logged-in desktop session: on Apple Silicon a Metal *device* may
        // still exist, but with no WindowServer connection there are no
        // screens and no drawable. Guard on both and fail with a clear message
        // instead of crashing deep in the C library.
        guard !NSScreen.screens.isEmpty, MTLCreateSystemDefaultDevice() != nil else {
            presentFatalAlert(
                "No display session",
                "Vakta renders its terminals with Metal and needs a logged-in "
                    + "desktop session. This usually means it was launched over "
                    + "SSH or remotely with no active display. Run it from the "
                    + "Mac's own screen instead."
            )
            NSApp.terminate(nil)
            return
        }

        buildMainMenu()

        let window = makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The initial session (created inside `SessionStore.init()`, before
        // this window -- and therefore `hostContainer` -- existed) already
        // asked to be selected and focused; that request's `makeFirstResponder`
        // call silently found `hostContainer.window == nil` and did nothing.
        // Re-issue it now that the container is actually in a window.
        if let id = sessionStore.selectedID {
            sessionStore.hostContainer.select(id)
        }

        keybindingMatcher.install { [weak self] index in
            self?.sessionStore.selectSession(at: index)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    private func makeWindow() -> NSWindow {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        let sidebarHost = NSHostingView(
            rootView: SidebarView().environmentObject(sessionStore)
        )
        sidebarHost.frame = NSRect(x: 0, y: 0, width: 220, height: 640)

        let terminalContainer = sessionStore.hostContainer
        terminalContainer.frame = NSRect(x: 0, y: 0, width: 860, height: 640)

        split.addArrangedSubview(sidebarHost)
        split.addArrangedSubview(terminalContainer)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vakta"
        window.contentView = split
        window.center()
        // `AppDelegate` (this object) holds `window` with a strong Swift
        // reference; AppKit's default `isReleasedWhenClosed = true` would
        // additionally release it when the user closes it, over-releasing
        // and crashing on next access (e.g. on quit).
        window.isReleasedWhenClosed = false
        return window
    }

    /// Settled design decision #5: the menu bar is deliberately free of
    /// every `keyEquivalent`. Any `⌘`-based key equivalent set here would
    /// let AppKit's menu system swallow the keystroke before it ever reaches
    /// the responder chain -- before even `KeybindingMatcher`'s local
    /// monitor gets a look, per Apple's documented event dispatch order.
    /// herdr (and Vakta's own chord) must see every key; menu items here are
    /// mouse/trackpad-only by design.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Vakta", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Vakta",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let sessionMenuItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")

        // "New Session" is a submenu of profiles; its first item (the default
        // profile) doubles as the plain "new session" action. Built from the
        // current profiles -- static built-ins today, so no live refresh yet.
        let newSessionItem = NSMenuItem(title: "New Session", action: nil, keyEquivalent: "")
        let profilesMenu = NSMenu(title: "New Session")
        for profile in sessionStore.profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(newSessionFromProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile
            profilesMenu.addItem(item)
        }
        newSessionItem.submenu = profilesMenu
        sessionMenu.addItem(newSessionItem)

        sessionMenuItem.submenu = sessionMenu
        mainMenu.addItem(sessionMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func presentFatalAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    @objc private func newSessionFromProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else {
            sessionStore.createSession()
            return
        }
        sessionStore.createSession(profile: profile)
    }
}
