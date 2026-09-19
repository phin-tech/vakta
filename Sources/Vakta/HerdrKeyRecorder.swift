//
//  HerdrKeyRecorder.swift
//  Vakta
//
//  Records a key press for the herdr config editor's Keys tab, the same way the
//  Keybindings pane records Vakta's own shortcuts: through the matcher's own
//  event monitor (`captureNext`), because a second local monitor would be
//  shadowed by the matcher's earlier-installed one (docs/architecture.md). The
//  press is converted by the pure `HerdrKeyChord.fromKeyEvent`. Only one row
//  records at a time; starting another replaces the pending capture.

import AppKit
import Combine

@MainActor
final class HerdrKeyRecorder: ObservableObject {
    /// The `HerdrKeyAction.name` currently waiting for a key, if any.
    @Published private(set) var recordingName: String?

    private var observation: AnyCancellable?

    /// Starts recording for `name`. `deliver` gets the recorded chord, or nil
    /// if the user cancelled with a bare ⎋ or the key couldn't be expressed.
    func start(
        name: String,
        matcher: KeybindingMatcher,
        usesPrefix: Bool,
        deliver: @escaping @MainActor (HerdrKeyChord?) -> Void
    ) {
        recordingName = name
        // Clears the recording state however the capture ends -- including the
        // matcher dropping it when the Preferences window resigns key.
        observation = matcher.$isCapturing.dropFirst().sink { [weak self] isCapturing in
            if !isCapturing { self?.recordingName = nil }
        }
        matcher.captureNext = { event in
            let flags = event.modifierFlags.intersection(SessionSwitcherKeyRouter.relevantModifierMask)
            if event.keyCode == 53, flags.isEmpty {
                deliver(nil)
                return
            }
            var modifiers = Set<HerdrKeyChord.Modifier>()
            if flags.contains(.control) { modifiers.insert(.ctrl) }
            if flags.contains(.option) { modifiers.insert(.alt) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.cmd) }
            deliver(HerdrKeyChord.fromKeyEvent(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: modifiers,
                usesPrefix: usesPrefix
            ))
        }
    }

    func cancel(matcher: KeybindingMatcher) {
        matcher.captureNext = nil
        recordingName = nil
    }
}
