//
//  TutorialContent.swift
//  Vakta
//
//  The welcome tour's steps and navigation. Each step shows the user's
//  actual shortcut -- their chord, else their leader sequence when leader
//  keys are on -- so a rebound or cleared key is never taught wrong.
//

import Foundation

enum TutorialShortcut {
    /// The chord bound to `command`, else the leader chord plus its sequence
    /// while leader keys are enabled, else nil (the step's text points at
    /// the command palette instead).
    static func label(
        for command: AppCommand,
        bindings: [Keybinding],
        leader: LeaderSettings,
        leaderSequences: [AppCommand: String]
    ) -> String? {
        if let binding = bindings.first(where: { $0.action == command }) {
            return binding.displayString
        }
        guard leader.isEnabled, let sequence = leaderSequences[command] else { return nil }
        return "\(leaderChord(leader)) \(sequence)"
    }

    static func leaderChord(_ leader: LeaderSettings) -> String {
        Keybinding.displayString(modifierMask: leader.modifierMask, keyCode: leader.keyCode)
    }
}

struct TutorialStep: Equatable {
    enum ID: Hashable {
        case welcome, multiplexerSetup, commandPalette, sessions, panes, leaderKeys, fileSidebar, preferences
    }

    var id: ID
    /// An SF Symbol name.
    var symbolName: String
    var title: String
    var body: String
    var shortcut: String?
}

enum TutorialContent {
    static func steps(
        bindings: [Keybinding],
        leader: LeaderSettings,
        leaderSequences: [AppCommand: String]
    ) -> [TutorialStep] {
        func shortcut(_ command: AppCommand) -> String? {
            TutorialShortcut.label(for: command, bindings: bindings, leader: leader, leaderSequences: leaderSequences)
        }

        return [
            TutorialStep(
                id: .welcome, symbolName: "terminal", title: "Welcome to Vakta",
                body: "A native terminal for herdr, tmux, and plain shells. This short tour covers the few things worth knowing on day one.",
                shortcut: nil),
            // The view shows live install status and actions for this step
            // (`MultiplexerSetupModel`).
            TutorialStep(
                id: .multiplexerSetup, symbolName: "shippingbox", title: "Set up herdr and tmux",
                body: "Vakta's sessions run inside herdr by default, or tmux. Install whichever you're missing; it runs in a new session so you can watch.",
                shortcut: nil),
            TutorialStep(
                id: .commandPalette, symbolName: "magnifyingglass", title: "Everything is in the command palette",
                body: "Open it to switch sessions and workspaces or run any command. Start typing a name to filter.",
                shortcut: shortcut(.openSessionSwitcher)),
            TutorialStep(
                id: .sessions, symbolName: "rectangle.stack", title: "Sessions live in the sidebar",
                body: "Each session is a terminal attached to a profile. Start a new one from the palette, or pick a profile from the Session menu.",
                shortcut: shortcut(.newSession)),
            TutorialStep(
                id: .panes, symbolName: "rectangle.split.2x1", title: "Split, zoom, and close panes",
                body: "In herdr and tmux sessions, pane and workspace actions are in the palette and on each workspace row's right-click menu.",
                shortcut: shortcut(.splitPaneRight)),
            TutorialStep(
                id: .leaderKeys, symbolName: "command",
                title: "Leader keys",
                body: leader.isEnabled
                    ? "Press the leader chord, then follow the hint panel one key at a time."
                    : "Prefer key sequences? Turn on leader keys in Preferences ▸ Keybindings, then a hint panel shows every command one key at a time.",
                shortcut: leader.isEnabled ? TutorialShortcut.leaderChord(leader) : nil),
            TutorialStep(
                id: .fileSidebar, symbolName: "sidebar.right", title: "Browse files beside the terminal",
                body: "The file sidebar shows the focused pane's working directory. Double-click to open a file.",
                shortcut: shortcut(.toggleFileSidebar)),
            TutorialStep(
                id: .preferences, symbolName: "gearshape", title: "Make it yours",
                body: "Rebind any shortcut, change themes and fonts, and manage profiles in Preferences. Reopen this tour anytime from the Help menu.",
                shortcut: shortcut(.openPreferences)),
        ]
    }
}

enum TutorialPosition: Equatable {
    case step(Int)
    case finished
}

enum TutorialNavigation {
    static func next(from index: Int, stepCount: Int) -> TutorialPosition {
        index + 1 < stepCount ? .step(index + 1) : .finished
    }

    static func previous(from index: Int) -> Int {
        max(index - 1, 0)
    }
}
