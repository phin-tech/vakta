//
//  KeybindingMatcher.swift
//  Vakta
//
//  Settled design decision #6: runs in front of every surface, in the
//  AppKit responder chain, and consumes-on-match / falls through otherwise.
//
//  Implemented as a *local* `NSEvent` monitor rather than an override of
//  `performKeyEquivalent(with:)` on some view: per Apple's documented event
//  dispatch order, a local monitor's handler runs before the event is
//  dispatched to the key window at all, so it sees every keyDown strictly
//  before `-[NSWindow performKeyEquivalent:]`/`-keyDown:` on whatever view is
//  first responder (i.e. strictly before `AppTerminalView`, and therefore
//  strictly before libghostty's key path and herdr). Returning `nil` from
//  the handler consumes the event; returning the event unchanged lets
//  AppKit's normal dispatch continue exactly as if this monitor didn't
//  exist.

import AppKit

@MainActor
final class KeybindingMatcher {
    var bindings: [Keybinding]

    private var monitor: Any?
    private let relevantModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(bindings: [Keybinding] = Keybinding.defaults) {
        self.bindings = bindings
    }

    /// Installs the monitor. `onMatch` receives the matched binding's
    /// 0-based `sessionIndex`.
    func install(onMatch: @escaping (Int) -> Void) {
        guard monitor == nil else { return }
        // Local monitor callbacks are documented to run on the main
        // thread/run loop that installed them; the `@MainActor` annotation
        // on the closure literal itself (rather than an inner
        // `MainActor.assumeIsolated`) is what lets it call the
        // actor-isolated `handle(_:onMatch:)` directly, with no Sendable
        // crossing of the non-Sendable `NSEvent` argument.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor [weak self] event in
            self?.handle(event, onMatch: onMatch) ?? event
        }
    }

    func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent, onMatch: (Int) -> Void) -> NSEvent? {
        let mods = event.modifierFlags.intersection(relevantModifierMask)
        guard let binding = bindings.first(where: { $0.modifierMask == mods && $0.keyCode == event.keyCode }) else {
            // No match: fall through so the key reaches the focused surface
            // and, from there, herdr.
            return event
        }
        onMatch(binding.sessionIndex)
        return nil
    }
}
