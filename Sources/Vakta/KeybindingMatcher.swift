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
    /// monitor that this one would shadow. Cleared after one delivery, or by
    /// `cancelCapture()`.
    var captureNext: (@MainActor (NSEvent) -> Void)? {
        didSet { isCapturing = captureNext != nil }
    }

    /// Mirrors whether `captureNext` is set, as `@Published` -- so the
    /// recording UI can observe a capture ending for a reason OTHER than
    /// its own button/Escape/delivered-key paths (namely
    /// `cancelCaptureWhenResigningKey(from:)`) and drop its own "Recording…"
    /// state instead of silently going stale.
    @Published private(set) var isCapturing = false

    /// Passthrough mode: while on, NO binding is matched -- every key falls
    /// through raw to the focused session. Transient (always off at launch);
    /// toggled by the double-tap chord. `@Published` so the UI can indicate it.
    @Published private(set) var passthrough = false {
        didSet { if passthrough { leaderPath = nil } }
    }

    /// Which double-tap modifier toggles `passthrough`. Persisted.
    @Published var passthroughToggle: PassthroughToggle {
        didSet { PassthroughSettingsPersistence.save(passthroughToggle, root: root) }
    }

    /// The leader-key flag and chord (see `LeaderKeys.swift`). Persisted;
    /// turning the flag off abandons any pending sequence. Enabling it (or
    /// moving the chord) unbinds a keybinding on the leader chord, which the
    /// leader would otherwise shadow forever.
    @Published var leaderSettings: LeaderSettings {
        didSet {
            LeaderSettingsPersistence.save(leaderSettings, root: root)
            if leaderSettings.isEnabled {
                removeBindings(onLeaderChord: leaderSettings)
            } else {
                leaderPath = nil
            }
        }
    }

    /// The pending leader sequence: `nil` when idle, `[]` right after the
    /// leader chord, then the keys typed so far. Transient (never persisted);
    /// `@Published` so the which-key overlay can follow it.
    @Published private(set) var leaderPath: [UInt16]?

    /// The tree leader sequences walk.
    let leaderRoot: LeaderNode = LeaderTree.defaultRoot

    /// The live availability snapshot a leader step decides against (the
    /// selected session's capabilities). Supplied by the app delegate.
    var commandContextProvider: () -> CommandContext = { .empty }

    /// Abandons a pending leader sequence (Esc in the overlay, app
    /// deactivation).
    func cancelLeader() {
        leaderPath = nil
    }

    /// Sets the leader chord, unbinding any keybinding on the same chord.
    /// One `leaderSettings` assignment, so one persist.
    func setLeaderChord(_ modifierMask: NSEvent.ModifierFlags, keyCode: UInt16) {
        var updated = leaderSettings
        updated.modifierMask = modifierMask.intersection(relevantModifierMask)
        updated.keyCode = keyCode
        removeBindings(onLeaderChord: updated)
        leaderSettings = updated
    }

    private func removeBindings(onLeaderChord settings: LeaderSettings) {
        let isOnChord = { (binding: Keybinding) in
            binding.modifierMask == settings.modifierMask && binding.keyCode == settings.keyCode
        }
        if bindings.contains(where: isOnChord) {
            bindings.removeAll(where: isOnChord)
        }
    }

    private func isLeaderChord(_ modifierMask: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        leaderSettings.isEnabled && leaderSettings.modifierMask == modifierMask && leaderSettings.keyCode == keyCode
    }

    /// Flips passthrough mode. Exposed so a UI affordance (the sidebar status
    /// indicator) can toggle it by click, in addition to the double-tap chord.
    func togglePassthrough() {
        passthrough.toggle()
    }

    private var monitor: Any?
    private let relevantModifierMask = SessionSwitcherKeyRouter.relevantModifierMask

    /// The AppKit responder the routing decision is based on. A closure
    /// (rather than reading `NSApp.keyWindow?.firstResponder` inline) so
    /// tests can supply a real, standalone `NSTextView` -- one that never
    /// needed a window or key-window status -- as the focused context
    /// without needing a live desktop session.
    var firstResponderProvider: () -> NSResponder? = { NSApp.keyWindow?.firstResponder }

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
        // Leader settings: defaults on a missing, corrupt or unreadable file,
        // and a corrupt file is left on disk (assigning in init fires no
        // `didSet`, so nothing is written here).
        switch LeaderSettingsPersistence.load(root: root) {
        case .loaded(let settings): leaderSettings = settings
        case .missing, .corrupt, .unreadable: leaderSettings = LeaderSettings()
        }

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
    func install(onMatch: @escaping (AppCommand) -> Void) {
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
            KeybindingMatcher.monitorCallbackResult(
                matcherIsAlive: self != nil,
                handledResult: self?.handle(event, onMatch: onMatch),
                event: event
            )
        }
    }

    /// The value the local-monitor callback returns for `event`: `nil`
    /// consumes it (AppKit dispatch stops here, so the key never reaches the
    /// terminal), the event itself falls through. Split out of the
    /// `addLocalMonitorForEvents` closure so the consume-vs-fall-through
    /// decision is unit-testable without a live event queue -- the inline
    /// `self?.handle(...) ?? event` it replaces silently coalesced a
    /// deliberate consume (`handle` -> `nil`) back into a fall-through.
    static func monitorCallbackResult(
        matcherIsAlive: Bool,
        handledResult: NSEvent?,
        event: NSEvent
    ) -> NSEvent? {
        guard matcherIsAlive else { return event }
        // Return `handle`'s result directly: it already returns `nil` to
        // consume and the event itself to fall through. Coalescing with
        // `?? event` here would turn a deliberate consume back into a
        // fall-through, leaking the raw key to the terminal.
        return handledResult
    }

    func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Drops any pending chord-recording capture without delivering a key to
    /// it. Recording is owned by whichever Preferences window started it;
    /// this lets that window relinquish ownership (see
    /// `cancelCaptureWhenResigningKey(from:)`) without the next keystroke,
    /// typed anywhere else once focus has moved on, being silently bound to
    /// the action instead of reaching its normal destination.
    func cancelCapture() {
        captureNext = nil
    }

    /// Registers an observer that cancels any in-progress capture the
    /// moment `window` stops being key -- covers losing ownership by
    /// switching away, not just closing. Returns the observer token so a
    /// caller with a shorter lifetime than this matcher can remove it;
    /// `PreferencesWindowController`'s window lives for the app's lifetime,
    /// so it doesn't need to.
    @discardableResult
    func cancelCaptureWhenResigningKey(from window: NSWindow) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelCapture()
            }
        }
    }

    /// Sets `binding.action`'s chord, replacing any existing binding for that
    /// action and unbinding any other action that already used this exact chord
    /// (the matcher's `first(where:)` would otherwise silently shadow one).
    func setBinding(_ modifierMask: NSEvent.ModifierFlags, keyCode: UInt16, for action: AppCommand) {
        // Normalize to the same mask `handle` matches against, so a caller
        // that passes an un-intersected `NSEvent.modifierFlags` (device
        // flags, caps lock, ...) can't store a chord that then never
        // matches. Built as one array and assigned once -- not
        // `removeAll` then `append` on the `@Published` property directly
        // -- so this is a single snapshot: one `didSet`/persist, and no
        // observer (the Preferences list, `KeybindingPersistence`) can ever
        // see the in-between state with the old chord already gone and the
        // new one not yet added.
        let normalizedMask = modifierMask.intersection(relevantModifierMask)
        // The leader is matched before bindings, so a binding on its chord
        // could never fire: refuse it rather than store a dead binding.
        guard !isLeaderChord(normalizedMask, keyCode: keyCode) else { return }
        var updated = bindings
        updated.removeAll { $0.action == action || ($0.modifierMask == normalizedMask && $0.keyCode == keyCode) }
        updated.append(Keybinding(modifierMask: normalizedMask, keyCode: keyCode, action: action))
        bindings = updated
    }

    /// Removes any chord bound to `action`.
    func clearBinding(for action: AppCommand) {
        bindings.removeAll { $0.action == action }
    }

    /// The chord currently bound to `action`, if any.
    func binding(for action: AppCommand) -> Keybinding? {
        bindings.first { $0.action == action }
    }

    // MARK: Mac-style preset

    /// Vakta's storage folder, where the config backup taken before applying
    /// the preset is written (see `MultiplexerConfigBackup`).
    var storageRoot: URL { root }

    var isMacStylePresetApplied: Bool { KeybindingPreset.macStyle.isApplied(in: bindings) }

    /// What applying the preset would change, for Preferences to show first.
    var macStylePresetChanges: [KeybindingPresetChange] { KeybindingPreset.macStyle.changes(from: bindings) }

    /// Applies the Mac-style chords, recording (alongside any earlier record)
    /// every binding they replaced so `revertMacStylePreset` can restore it
    /// after a restart.
    func applyMacStylePreset() {
        let result = KeybindingPreset.macStyle.apply(to: bindings)
        var replaced = presetRecord()?.replaced ?? []
        for binding in result.replaced where !replaced.contains(binding) {
            replaced.append(binding)
        }
        KeybindingPresetPersistence.store(root: root).save(KeybindingPresetRecord(replaced: replaced))
        bindings = result.bindings
    }

    /// Removes the preset's chords and restores what they replaced; without
    /// a readable record, the shipped defaults stand in for it.
    func revertMacStylePreset() {
        let candidates = presetRecord()?.replaced ?? Keybinding.defaults
        bindings = KeybindingPreset.macStyle.revert(bindings, restoring: candidates)
        KeybindingPresetPersistence.store(root: root).save(KeybindingPresetRecord(replaced: []))
    }

    private func presetRecord() -> KeybindingPresetRecord? {
        guard case .loaded(let record) = KeybindingPresetPersistence.store(root: root).load() else { return nil }
        return record
    }

    /// Restores the shipped defaults (session chords; sidebar/preferences
    /// unbound).
    func resetToDefaults() {
        bindings = Keybinding.defaults
    }

    func handle(_ event: NSEvent, onMatch: (AppCommand) -> Void) -> NSEvent? {
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

        // A pending leader sequence owns every key until it commits or
        // cancels; each one is consumed, including an undefined key.
        if let path = leaderPath {
            switch LeaderSequencePlanner.step(
                root: leaderRoot,
                path: path,
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                context: commandContextProvider()
            ) {
            case .descend(let next), .back(let next):
                leaderPath = next
            case .commit(let command):
                leaderPath = nil
                onMatch(command)
            case .cancel:
                leaderPath = nil
            }
            return nil
        }

        let mods = event.modifierFlags.intersection(relevantModifierMask)
        let isTextEntryFocused = firstResponderProvider() is NSTextView

        // The leader chord starts a sequence -- except while a text field is
        // being edited, where (like any contextSensitive chord) the key keeps
        // its normal meaning.
        if isLeaderChord(mods, keyCode: event.keyCode) {
            guard !isTextEntryFocused else { return event }
            leaderPath = []
            return nil
        }

        guard let binding = bindings.first(where: { $0.modifierMask == mods && $0.keyCode == event.keyCode }) else {
            // No match: fall through so the key reaches the focused surface
            // and, from there, herdr.
            return event
        }
        // A text-editing view (Preferences fields, the profile editor, the
        // switcher's own search field) owns first responder: only a global
        // action still fires. Any contextSensitive action -- including a
        // user-recorded chord that happens to collide with a standard
        // editing shortcut like ⌘V -- falls through to its normal text
        // meaning instead of being silently stolen app-wide.
        guard KeybindingRoutingPlanner.shouldConsume(action: binding.action, isTextEntryFocused: isTextEntryFocused) else {
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
