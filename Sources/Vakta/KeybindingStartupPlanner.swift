//
//  KeybindingStartupPlanner.swift
//  Vakta
//
//  The pure startup decision `KeybindingMatcher.init` acts on: given what
//  `KeybindingPersistence.load` returned, which bindings to use in memory and
//  whether the result needs writing back. Kept separate from `KeybindingMatcher`
//  (which owns the AppKit event monitor and actual I/O) so the decision is
//  testable without an `NSEvent` monitor or real files.

import Foundation

enum PassthroughStartupDecision: Equatable {
    case use(toggle: PassthroughToggle, shouldPersist: Bool)
}

enum PassthroughStartupPlanner {
    /// Missing (first launch): seed `.shift` and persist it. Corrupt/
    /// unreadable: use `.shift` in memory for this run only -- persisting
    /// would silently discard whatever valid choice is actually on disk.
    static func plan(for outcome: FileLoadOutcome<PassthroughToggle>) -> PassthroughStartupDecision {
        switch outcome {
        case .missing:
            return .use(toggle: .shift, shouldPersist: true)
        case .loaded(let toggle):
            return .use(toggle: toggle, shouldPersist: false)
        case .corrupt, .unreadable:
            return .use(toggle: .shift, shouldPersist: false)
        }
    }
}

enum KeybindingStartupDecision: Equatable {
    /// Use `bindings`. `shouldPersist` is true when the in-memory result
    /// differs from -- or should replace -- what's on disk (first launch,
    /// or a migration from an older schema version).
    case use(bindings: [Keybinding], shouldPersist: Bool)
}

enum KeybindingStartupPlanner {
    /// - Missing file (first launch): seed and persist the defaults.
    /// - Loaded: apply any step-wise migrations for the payload's version,
    ///   persisting only if a migration actually ran.
    /// - Corrupt/unreadable: fall back to in-memory defaults for this run,
    ///   but do NOT persist -- overwriting would destroy the user's saved
    ///   bindings if the read failure is transient (e.g. a momentary
    ///   permissions issue) or discard data worth recovering by hand.
    static func plan(for outcome: FileLoadOutcome<StoredKeybindingsPayload>) -> KeybindingStartupDecision {
        switch outcome {
        case .missing:
            return .use(bindings: Keybinding.defaults, shouldPersist: true)

        case .loaded(let payload):
            var bindings = payload.bindings
            if payload.version < 2 {
                addDefaultIfFree(&bindings, chord: Keybinding.kKeyCode, action: .openSessionSwitcher)
            }
            if payload.version < 3 {
                addDefaultIfFree(&bindings, chord: Keybinding.qKeyCode, action: .quit)
            }
            if payload.version < 4 {
                addDefaultIfFree(&bindings, chord: Keybinding.cKeyCode, action: .copy)
                addDefaultIfFree(&bindings, chord: Keybinding.vKeyCode, action: .paste)
                addDefaultIfFree(&bindings, chord: Keybinding.xKeyCode, action: .cut)
            }
            if payload.version < 5 {
                addDefaultIfFree(&bindings, chord: Keybinding.aKeyCode, action: .selectAll)
                addDefaultIfFree(&bindings, chord: Keybinding.wKeyCode, action: .closeWindow)
            }
            return .use(bindings: bindings, shouldPersist: payload.version < KeybindingFileCodec.currentVersion)

        case .corrupt, .unreadable:
            return .use(bindings: Keybinding.defaults, shouldPersist: false)
        }
    }

    /// Appends a `⌘<chord>` default binding for `action` unless the action is
    /// already bound or that exact ⌘ chord is already taken.
    private static func addDefaultIfFree(
        _ bindings: inout [Keybinding],
        chord keyCode: UInt16,
        action: KeybindingAction
    ) {
        let actionBound = bindings.contains { $0.action == action }
        let chordTaken = bindings.contains { $0.modifierMask == [.command] && $0.keyCode == keyCode }
        guard !actionBound, !chordTaken else { return }
        bindings.append(Keybinding(modifierMask: [.command], keyCode: keyCode, action: action))
    }
}
