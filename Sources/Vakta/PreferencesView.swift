//
//  PreferencesView.swift
//  Vakta
//
//  The Preferences window's content: a sidebar of sections on the left, the
//  selected section's editor on the right. Only "Keybindings" exists today;
//  the `PreferencesSection` enum is the seam where future panes (appearance,
//  profiles, …) slot in.

import SwiftUI

/// One row in the Preferences sidebar.
enum PreferencesSection: String, CaseIterable, Identifiable {
    case appearance
    case terminal
    case sessions
    case notifications
    case keybindings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .sessions: return "Sessions"
        case .notifications: return "Notifications"
        case .keybindings: return "Keybindings"
        }
    }

    /// SF Symbol shown next to the title.
    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .terminal: return "terminal"
        case .sessions: return "macwindow"
        case .notifications: return "bell"
        case .keybindings: return "keyboard"
        }
    }
}

struct PreferencesView: View {
    @State private var selection: PreferencesSection = .appearance

    var body: some View {
        NavigationSplitView {
            List(PreferencesSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch selection {
            case .appearance:
                AppearancePreferencesView()
            case .terminal:
                TerminalPreferencesView()
            case .sessions:
                SessionsPreferencesView()
            case .notifications:
                NotificationsPreferencesView()
            case .keybindings:
                KeybindingsPreferencesView()
            }
        }
    }
}
