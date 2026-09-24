//
//  KeybindingPreset.swift
//  Vakta
//
//  Opt-in chord presets -- today the Mac-style (iTerm-flavoured) shortcuts
//  for herdr and tmux. Vakta intercepts these ⌘ chords and runs the matching
//  multiplexer action itself: ⌘ never reaches a multiplexer through the
//  terminal, so the herdr/tmux configs are left alone and their prefix keys
//  keep working.
//
//  One chord per command and one command per chord (`KeybindingMatcher`'s
//  model), so applying takes chords over and moves commands; everything it
//  replaced is returned for a revert that won't clobber later edits.
//

import AppKit

struct KeybindingPresetChange: Equatable {
    /// The chord the preset binds.
    let binding: Keybinding
    /// The command that currently owns this chord and will lose it.
    let displacedCommand: AppCommand?
    /// The command's current chord, which the preset replaces.
    let previousChord: Keybinding?
}

struct KeybindingPresetApplication: Equatable {
    let bindings: [Keybinding]
    /// Every binding applying removed -- chords taken over and commands'
    /// previous chords -- for `revert`.
    let replaced: [Keybinding]
}

struct KeybindingPreset: Equatable {
    let bindings: [Keybinding]

    /// ⌘T new workspace · ⌘D / ⌘⇧D split right / down · ⌘W close pane ·
    /// ⌘⇧W close workspace · ⌘⇧↩ zoom · ⌘⌥ arrows focus a neighbouring pane ·
    /// ⌘1…⌘9 go to a workspace · ⌘⇧[ / ⌘⇧] previous / next workspace.
    static let macStyle = KeybindingPreset(bindings: [
        Keybinding(modifierMask: [.command], keyCode: 17, action: .newWorkspace),
        Keybinding(modifierMask: [.command], keyCode: 2, action: .splitPaneRight),
        Keybinding(modifierMask: [.command, .shift], keyCode: 2, action: .splitPaneDown),
        Keybinding(modifierMask: [.command], keyCode: Keybinding.wKeyCode, action: .closePane),
        Keybinding(modifierMask: [.command, .shift], keyCode: Keybinding.wKeyCode, action: .closeWorkspace),
        Keybinding(modifierMask: [.command, .shift], keyCode: 36, action: .zoomPane),
        Keybinding(modifierMask: [.command, .option], keyCode: 123, action: .focusPaneLeft),
        Keybinding(modifierMask: [.command, .option], keyCode: 124, action: .focusPaneRight),
        Keybinding(modifierMask: [.command, .option], keyCode: 126, action: .focusPaneUp),
        Keybinding(modifierMask: [.command, .option], keyCode: 125, action: .focusPaneDown),
    ] + Keybinding.digitKeyCodes.enumerated().map {
        Keybinding(modifierMask: [.command], keyCode: $0.element, action: .focusWorkspace($0.offset))
    } + [
        Keybinding(modifierMask: [.command, .shift], keyCode: 33, action: .previousWorkspace),
        Keybinding(modifierMask: [.command, .shift], keyCode: 30, action: .nextWorkspace),
    ])

    func isApplied(in current: [Keybinding]) -> Bool {
        bindings.allSatisfy(current.contains)
    }

    /// What applying would change, one entry per preset chord.
    func changes(from current: [Keybinding]) -> [KeybindingPresetChange] {
        bindings.map { preset in
            KeybindingPresetChange(
                binding: preset,
                displacedCommand: current.first { Self.sameChord($0, preset) && $0.action != preset.action }?.action,
                previousChord: current.first { $0.action == preset.action && !Self.sameChord($0, preset) }
            )
        }
    }

    func apply(to current: [Keybinding]) -> KeybindingPresetApplication {
        var result = current
        var replaced: [Keybinding] = []
        for preset in bindings {
            let conflicting = { (existing: Keybinding) in existing.action == preset.action || Self.sameChord(existing, preset) }
            replaced += result.filter { conflicting($0) && $0 != preset }
            result.removeAll(where: conflicting)
            result.append(preset)
        }
        return KeybindingPresetApplication(bindings: result, replaced: replaced)
    }

    /// Removes the preset's chords that are still exactly as it set them,
    /// then restores each `candidate` whose command is unbound and whose
    /// chord is free -- so a chord the user rebound since is kept, and
    /// nothing is restored onto a chord that's been taken.
    func revert(_ current: [Keybinding], restoring candidates: [Keybinding]) -> [Keybinding] {
        var result = current.filter { !bindings.contains($0) }
        for candidate in candidates where !bindings.contains(candidate) {
            let commandBound = result.contains { $0.action == candidate.action }
            let chordTaken = result.contains { Self.sameChord($0, candidate) }
            if !commandBound && !chordTaken { result.append(candidate) }
        }
        return result
    }

    /// The chord table for Preferences and the tour, folding the four pane
    /// directions, the nine workspace digits, and previous/next into one row
    /// each.
    var summaryRows: [(chords: String, title: String)] {
        var rows: [(chords: String, title: String)] = []
        var emittedFolds = Set<String>()
        for binding in bindings {
            let fold: (key: String, members: [Keybinding], chords: String, title: String)?
            switch binding.action {
            case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown:
                let members = bindings.filter { [.focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown].contains($0.action) }
                let modifiers = Keybinding.displayString(modifierMask: binding.modifierMask, keyCode: 0).dropLast(Keybinding.keyGlyph(for: 0).count)
                fold = ("focus", members, modifiers + members.map { Keybinding.keyGlyph(for: $0.keyCode) }.joined(), "Focus Pane in Direction")
            case .focusWorkspace:
                let members = bindings.filter { if case .focusWorkspace = $0.action { return true } else { return false } }
                fold = ("digits", members, "\(members.first?.displayString ?? "")…\(members.last?.displayString ?? "")", "Go to Workspace 1–\(members.count)")
            case .previousWorkspace, .nextWorkspace:
                let members = bindings.filter { [.previousWorkspace, .nextWorkspace].contains($0.action) }
                fold = ("cycle", members, members.map(\.displayString).joined(separator: " "), "Previous / Next Workspace")
            default:
                fold = nil
            }
            if let fold {
                if emittedFolds.insert(fold.key).inserted { rows.append((fold.chords, fold.title)) }
            } else {
                rows.append((binding.displayString, binding.action.title))
            }
        }
        return rows
    }

    /// Only what applying would displace, in preset order: a command's
    /// existing chord it moves, and a chord it takes from another command.
    func changeDescriptions(from current: [Keybinding]) -> [String] {
        changes(from: current).flatMap { change -> [String] in
            var lines: [String] = []
            if let previous = change.previousChord {
                lines.append("\(change.binding.action.title): \(previous.displayString) → \(change.binding.displayString)")
            }
            if let displaced = change.displacedCommand {
                lines.append("\(change.binding.displayString): \(displaced.title) → \(change.binding.action.title)")
            }
            return lines
        }
    }

    private static func sameChord(_ lhs: Keybinding, _ rhs: Keybinding) -> Bool {
        lhs.modifierMask == rhs.modifierMask && lhs.keyCode == rhs.keyCode
    }
}

/// What applying the Mac-style preset replaced, so revert can restore it
/// across restarts.
struct KeybindingPresetRecord: Equatable, Codable {
    var replaced: [Keybinding]
}

enum KeybindingPresetPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<KeybindingPresetRecord>> {
        PersistedFileStore(root: root, fileName: "keybinding-preset.json", codec: JSONCodec())
    }
}
