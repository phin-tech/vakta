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
//
//  Also the single source of truth for the user's bindings: loaded from and
//  saved to `KeybindingPersistence` (an `ObservableObject` so the Preferences
//  pane can edit `bindings` directly and have it take effect + persist live).

import AppKit
import Combine

@MainActor
final class KeybindingMatcher: ObservableObject {
    /// The live bindings. Edited by the Preferences pane; every change is
    /// persisted immediately. The event monitor reads this on each keyDown, so
    /// edits take effect with no reinstall.
    @Published var bindings: [Keybinding] {
        didSet { KeybindingPersistence.save(bindings, root: root) }
    }

    private let root: URL

    /// When set, the *next* keyDown is delivered here (and consumed) instead of
    /// being matched -- this is how the Preferences "record a chord" flow
    /// captures a key press through this same monitor, rather than a second
    /// monitor that this one would shadow. Cleared after one delivery.
    var captureNext: (@MainActor (NSEvent) -> Void)?

    /// Passthrough mode: while on, NO binding is matched -- every key falls
    /// through raw to the focused session. Transient (always off at launch);
    /// toggled by the double-tap chord. `@Published` so the UI can indicate it.
    @Published private(set) var passthrough = false

    /// Which double-tap modifier toggles `passthrough`. Persisted.
    @Published var passthroughToggle: PassthroughToggle {
        didSet { PassthroughSettingsPersistence.save(passthroughToggle, root: root) }
    }

    /// Flips passthrough mode. Exposed so a UI affordance (the sidebar status
    /// indicator) can toggle it by click, in addition to the double-tap chord.
    func togglePassthrough() {
        passthrough.toggle()
    }

    private var monitor: Any?
    private let relevantModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    // Double-tap detection state (for the passthrough toggle).
    private var lastRelevantFlags: NSEvent.ModifierFlags = []
    private var lastTapTime: TimeInterval = 0
    private var sawKeyDuringHold = false
    private let doubleTapWindow: TimeInterval = 0.4

    init(root: URL) {
        self.root = root

        // Plan what to do with the saved passthrough toggle. Assigning
        // `passthroughToggle` in init does not fire its `didSet`, so a
        // startup write (seed only) is issued explicitly. A corrupt or
        // unreadable file is deliberately NOT overwritten here -- see
        // `PassthroughStartupPlanner`.
        let passthroughDecision = PassthroughStartupPlanner.plan(for: PassthroughSettingsPersistence.load(root: root))
        switch passthroughDecision {
        case .use(let toggle, let shouldPersist):
            passthroughToggle = toggle
            if shouldPersist {
                PassthroughSettingsPersistence.save(toggle, root: root)
            }
        }

        // Plan what to do with the saved keybindings file, then apply it.
        // Assigning `bindings` in init does not fire its `didSet`, so a
        // startup write (seed or migration) is issued explicitly. A corrupt
        // or unreadable file is deliberately NOT overwritten here -- see
        // `KeybindingStartupPlanner`.
        let decision = KeybindingStartupPlanner.plan(for: KeybindingPersistence.load(root: root))
        switch decision {
        case .use(let planned, let shouldPersist):
            bindings = planned
            if shouldPersist {
                KeybindingPersistence.save(planned, root: root)
            }
        }
    }

    /// Installs the monitor. `onMatch` receives the matched binding's action.
    func install(onMatch: @escaping (KeybindingAction) -> Void) {
        guard monitor == nil else { return }
        // Local monitor callbacks are documented to run on the main
        // thread/run loop that installed them; the `@MainActor` annotation
        // on the closure literal itself (rather than an inner
        // `MainActor.assumeIsolated`) is what lets it call the
        // actor-isolated `handle(_:onMatch:)` directly, with no Sendable
        // crossing of the non-Sendable `NSEvent` argument.
        // Also watch `.flagsChanged` for the passthrough double-tap chord --
        // modifier presses/releases arrive as flagsChanged, not keyDown.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { @MainActor [weak self] event in
            self?.handle(event, onMatch: onMatch) ?? event
        }
    }

    func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Sets `binding.action`'s chord, replacing any existing binding for that
    /// action and unbinding any other action that already used this exact chord
    /// (the matcher's `first(where:)` would otherwise silently shadow one).
    func setBinding(_ modifierMask: NSEvent.ModifierFlags, keyCode: UInt16, for action: KeybindingAction) {
        bindings.removeAll { $0.action == action || ($0.modifierMask == modifierMask && $0.keyCode == keyCode) }
        bindings.append(Keybinding(modifierMask: modifierMask, keyCode: keyCode, action: action))
    }

    /// Removes any chord bound to `action`.
    func clearBinding(for action: KeybindingAction) {
        bindings.removeAll { $0.action == action }
    }

    /// The chord currently bound to `action`, if any.
    func binding(for action: KeybindingAction) -> Keybinding? {
        bindings.first { $0.action == action }
    }

    /// Restores the shipped defaults (session chords; sidebar/preferences
    /// unbound).
    func resetToDefaults() {
        bindings = Keybinding.defaults
    }

    private func handle(_ event: NSEvent, onMatch: (KeybindingAction) -> Void) -> NSEvent? {
        // Modifier press/release: never consumed (modifiers must reach the
        // terminal); used only to detect the passthrough double-tap.
        if event.type == .flagsChanged {
            detectPassthroughToggle(event)
            return event
        }

        // keyDown: any key press invalidates a pending double-tap (so e.g.
        // Shift+A never counts as a Shift tap).
        sawKeyDuringHold = true

        // A recording session claims the next key, whatever it is, and consumes
        // it so it never reaches a surface or matches a binding.
        if let capture = captureNext {
            captureNext = nil
            capture(event)
            return nil
        }

        // Passthrough: no matching at all -- every key falls through raw.
        if passthrough {
            return event
        }

        let mods = event.modifierFlags.intersection(relevantModifierMask)
        guard let binding = bindings.first(where: { $0.modifierMask == mods && $0.keyCode == event.keyCode }) else {
            // No match: fall through so the key reaches the focused surface
            // and, from there, herdr.
            return event
        }
        onMatch(binding.action)
        return nil
    }

    /// Detects a clean double-tap of the configured toggle modifier (press +
    /// release, twice, within the window, with no other key or modifier
    /// involved) and flips `passthrough`.
    private func detectPassthroughToggle(_ event: NSEvent) {
        guard let toggleMod = passthroughToggle.modifier else { return }
        let current = event.modifierFlags.intersection(relevantModifierMask)
        let previous = lastRelevantFlags
        lastRelevantFlags = current

        // Press of exactly the toggle modifier alone: begin a clean hold.
        if current == toggleMod, previous.isEmpty {
            sawKeyDuringHold = false
            return
        }

        // Release completing a clean tap: previous was exactly the toggle
        // modifier, nothing is held now, and no key interrupted the hold.
        guard current.isEmpty, previous == toggleMod, !sawKeyDuringHold else { return }
        let now = event.timestamp
        if now - lastTapTime <= doubleTapWindow {
            lastTapTime = 0
            passthrough.toggle()
        } else {
            lastTapTime = now
        }
    }
}
