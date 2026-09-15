//
//  TerminalContainer.swift
//  Vakta
//
//  The AppKit-owned home for every session's terminal surface.
//
//  Settled design decision #4 is the whole point of this file: NEVER create
//  or destroy a surface on sidebar selection, and NEVER host a live surface
//  behind a SwiftUI conditional. Every `AppTerminalView` (the `TerminalView`
//  typealias on macOS -- see the resolved libghostty-spm checkout's
//  `View/TerminalView.swift`) this container creates stays a subview, alive,
//  for the session's entire lifetime. Switching the visible session flips
//  `isHidden` + `setSurfaceVisible(_:)` on exactly two views; it never adds,
//  removes, or recreates anything. Only `removeSession(_:)` -- called when a
//  session actually closes -- tears a surface down, and it does so simply by
//  dropping the last strong reference to the view: `AppTerminalView`'s
//  `deinit` walks `TerminalSurfaceCoordinator.deinit` ->
//  `tearDownSurface(removingBridgeFrom:)` -> `surface.free()`, which is also
//  what ends herdr's pty.

import AppKit
import GhosttyTerminal
import SwiftUI

@MainActor
final class TerminalHostContainerView: NSView {
    private var viewsByID: [Session.ID: TerminalView] = [:]
    private(set) var selectedID: Session.ID?

    /// Adds a new session's surface, hidden and not yet current. Call
    /// `select(_:)` to bring it to the front.
    ///
    /// `delegate`, `controller`, and `configuration` are set before
    /// `addSubview`. `TerminalSurfaceCoordinator` (internal to
    /// GhosttyTerminal) only actually builds a `ghostty_surface_t` once the
    /// view both has all three AND is attached to a window with a non-zero
    /// size; setting them first means the real build happens the moment
    /// `addSubview` attaches this view into an already-windowed container
    /// (or, if this container itself isn't windowed yet, the moment it
    /// later becomes so -- `AppTerminalView.viewDidMoveToWindow` retries the
    /// build automatically whenever `surface == nil`, so no polling or
    /// pending-state tracking is needed on Vakta's side).
    func addSession(_ session: Session) {
        let view = TerminalView(frame: bounds)
        view.autoresizingMask = [.width, .height]

        // `TerminalViewState` already conforms to every
        // `TerminalSurfaceViewDelegate` sub-protocol Vakta needs (title,
        // close, pwd, ...); handing it straight in is the "prefer the
        // wrapper's provided types" path called out in the task brief.
        view.delegate = session.viewState
        view.controller = session.controller
        view.configuration = session.options

        view.isHidden = true
        viewsByID[session.id] = view
        addSubview(view)
        view.setSurfaceVisible(false)
    }

    /// Removes a session's view -- see the type doc comment for why this,
    /// and only this, is what frees the surface.
    func removeSession(_ id: Session.ID) {
        guard let view = viewsByID.removeValue(forKey: id) else { return }
        view.setSurfaceVisible(false)
        view.removeFromSuperview()
        if selectedID == id { selectedID = nil }
    }

    /// Makes `id`'s surface the one that is visible, drawing, and focused.
    /// Never creates or destroys a surface.
    func select(_ id: Session.ID) {
        guard viewsByID[id] != nil else { return }

        if let previousID = selectedID, previousID != id, let previousView = viewsByID[previousID] {
            previousView.setSurfaceVisible(false)
            previousView.isHidden = true
        }

        selectedID = id
        guard let view = viewsByID[id] else { return }
        view.isHidden = false
        view.setSurfaceVisible(true)

        // One runloop turn so AppKit's layout pass for `isHidden = false`
        // (and, for a brand-new session, the view's own window attachment)
        // settles before first responder is reassigned. Mirrors the
        // wrapper's own deferred-focus pattern
        // (`TerminalViewState.requestFocus()` / `AppTerminalView.viewDidMoveToWindow`).
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.selectedID == id, let window = self.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

// MARK: - Optional SwiftUI bridge

/// An `NSViewRepresentable` bridge to a *pre-existing*, externally owned
/// `TerminalHostContainerView`. It deliberately never creates the container
/// itself: SwiftUI-driven creation of an `NSViewRepresentable`'s view is not
/// guaranteed to run exactly once over the view's logical lifetime (a diff
/// can call `makeNSView` again, or tear the representable down, for reasons
/// unrelated to session state), and that is exactly the failure mode
/// settled design decision #4 rules out.
///
/// `Vakta/App.swift` does not use this: the container is instead a direct,
/// permanent subview of an `NSSplitView` that IS the window's content view,
/// so SwiftUI never owns the container at all and the representable
/// lifetime question does not arise. This type is kept because the task's
/// suggested structure calls for a `TerminalContainer.swift` with "AppKit
/// container + `NSViewRepresentable` bridge" -- a host that genuinely needs
/// the container reachable from inside a larger SwiftUI-only layout can use
/// it safely, precisely because `container` is supplied from outside rather
/// than instantiated here.
struct TerminalContainerRepresentable: NSViewRepresentable {
    let container: TerminalHostContainerView

    func makeNSView(context _: Context) -> TerminalHostContainerView {
        container
    }

    func updateNSView(_: TerminalHostContainerView, context _: Context) {
        // Deliberately empty: `SessionStore` drives `container` imperatively
        // (`addSession` / `removeSession` / `select`) as sessions change,
        // never through SwiftUI's declarative update pass.
    }
}
