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
import Combine
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
    private var splitView: NSSplitView?
    private var sidebarObserver: AnyCancellable?
    private let sessionStore = SessionStore()
    private let keybindingMatcher = KeybindingMatcher()
    private lazy var preferencesController = PreferencesWindowController(
        keybindingMatcher: keybindingMatcher
    )

    /// Sidebar widths: a full panel, and a narrow icon rail when collapsed.
    private let expandedSidebarWidth: CGFloat = 220
    private let collapsedSidebarWidth: CGFloat = 56

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

        keybindingMatcher.install { [weak self] action in
            guard let self else { return }
            switch action {
            case .selectSession(let index): self.sessionStore.selectSession(at: index)
            case .toggleSidebar: self.sessionStore.toggleSidebar()
            case .openPreferences: self.preferencesController.show()
            }
        }

        // Drive the sidebar width off the store's collapsed flag, which the
        // sidebar's own button and the View menu both toggle.
        sidebarObserver = sessionStore.$sidebarCollapsed.sink { [weak self] collapsed in
            self?.applySidebarWidth(collapsed: collapsed)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_: Notification) {
        // Keep the "Attach existing" list fresh when returning to the app.
        sessionStore.refreshDiscovery()
    }

    /// Moves the divider between the full panel and the icon rail. Done without
    /// implicit animation: animating `setPosition` (especially with a nested
    /// `layoutSubtreeIfNeeded`) leaves a stale divider streak. We force a clean
    /// full redraw instead.
    private func applySidebarWidth(collapsed: Bool) {
        guard let splitView else { return }
        let target = collapsed ? collapsedSidebarWidth : expandedSidebarWidth
        splitView.setPosition(target, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        splitView.needsDisplay = true
        splitView.window?.viewsNeedDisplay = true
    }

    @objc private func toggleSidebar() {
        sessionStore.toggleSidebar()
    }

    @objc private func showPreferences() {
        preferencesController.show()
    }

    private func makeWindow() -> NSWindow {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        let sidebarHost = NSHostingView(
            rootView: SidebarView().environmentObject(sessionStore)
        )
        sidebarHost.frame = NSRect(x: 0, y: 0, width: expandedSidebarWidth, height: 640)
        // Layer-backed + opaque so a resize can't leave a background seam.
        sidebarHost.wantsLayer = true

        let terminalContainer = sessionStore.hostContainer
        terminalContainer.frame = NSRect(x: 0, y: 0, width: 860, height: 640)

        split.addArrangedSubview(sidebarHost)
        split.addArrangedSubview(terminalContainer)
        // Sidebar keeps its width when the window resizes; the terminal flexes.
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        self.splitView = split

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
        // No ⌘, key equivalent: settled design decision #5 keeps every menu
        // item keyless so keystrokes reach herdr. Preferences is reachable by
        // mouse here, and the user can bind it (and Toggle Sidebar) to a chord
        // inside the pane -- that goes through `KeybindingMatcher`, which by
        // design sees keys before the menu ever could.
        let preferencesItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(showPreferences),
            keyEquivalent: ""
        )
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
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

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // No key equivalent, to keep every keystroke flowing to the terminal
        // (settled design decision #5). The sidebar's own button and the
        // Ctrl+Shift+num chords are the keyboard-free / rebindable paths.
        let toggleItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar),
            keyEquivalent: ""
        )
        toggleItem.target = self
        viewMenu.addItem(toggleItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

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
