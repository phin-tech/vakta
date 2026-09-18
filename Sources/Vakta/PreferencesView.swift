//
//  PreferencesView.swift
//  Vakta
//
//  The Preferences window's content: a sidebar of sections on the left, the
//  selected section's editor on the right. `PreferencesSection` is the seam
//  where a new pane slots in -- add a case, a `title`/`symbol`, and a
//  `detail` branch below.

import SwiftUI

/// One row in the Preferences sidebar.
enum PreferencesSection: String, CaseIterable, Identifiable {
    case appearance
    case terminal
    case sessions
    case notifications
    case keybindings
    case herdr
    case editor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .sessions: return "Sessions"
        case .notifications: return "Notifications"
        case .keybindings: return "Keybindings"
        case .herdr: return "Herdr"
        case .editor: return "Editor"
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
        case .herdr: return "rectangle.on.rectangle"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct PreferencesView: View {
    @State private var selection: PreferencesSection = .appearance
    @EnvironmentObject private var persistenceFailures: PersistenceFailureCenter
    @EnvironmentObject private var sessionStore: SessionStore

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
            case .herdr:
                HerdrPreferencesView()
            case .editor:
                EditorPreferencesView()
            }
        }
        // Tints controls (toggles, pickers, the section list's own selection
        // highlight, buttons) with the terminal theme's accent -- the same
        // thread the sidebar and ⌘K palette already pull on. Deliberately
        // NOT a solid background repaint like those two: this window is
        // standard Form controls macOS didn't design to sit on an arbitrary
        // background, so it keeps the system material.
        .tint(Color(nsColor: sessionStore.terminalAccentColor))
        .safeAreaInset(edge: .bottom) {
            if let message = persistenceFailures.latestMessage {
                saveFailureBanner(message)
            }
        }
    }

    /// A save failure is otherwise invisible -- every persistence call site
    /// discards its result (see `PersistedFileStore.save`). Shown here,
    /// rather than in the main window, because Preferences is a plain
    /// SwiftUI layout; the main window's sidebar is hand-tuned AppKit frame
    /// math (see `App.makeWindow`) that a new floating element risks
    /// disturbing without a way to visually verify it in this environment.
    private func saveFailureBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { persistenceFailures.dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial)
    }
}
