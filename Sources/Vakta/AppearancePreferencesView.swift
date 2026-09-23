//
//  AppearancePreferencesView.swift
//  Vakta
//
//  The "Appearance" preferences pane: pick the app's window/sidebar chrome
//  theme. Applies immediately (via `AppearanceStore.didSet`); no Save/Cancel.

import SwiftUI

struct AppearancePreferencesView: View {
    @EnvironmentObject private var store: AppearanceStore
    @EnvironmentObject private var sidebarSettings: SidebarSettingsStore
    @EnvironmentObject private var herdrPreferences: HerdrPreferencesStore
    @EnvironmentObject private var fileSidebarPreferences: FileSidebarPreferencesStore
    @EnvironmentObject private var statusBarPreferences: StatusBarPreferencesStore

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $store.appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Sets the color of Vakta's window and sidebar. Terminal "
                    + "colors are controlled by the terminal theme, not this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sidebar style", selection: $store.sidebarFont) {
                    ForEach(SidebarFontMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                if store.sidebarFont == .matchTerminal {
                    // Validate before `Int(_:)`: the stored value is kept as
                    // decoded, so a hand-edited file can hold a non-finite
                    // or huge number that would trap a direct conversion.
                    Stepper {
                        let displaySize = TerminalFontSizeValidator.effective(store.sidebarFontSize)
                        Text(displaySize > 0
                            ? "Sidebar font size: \(Int(displaySize)) pt"
                            : "Sidebar font size: Match terminal")
                    } onIncrement: {
                        let current = TerminalFontSizeValidator.effective(store.sidebarFontSize)
                        store.sidebarFontSize = current < 9 ? 9 : min(32, current + 1)
                    } onDecrement: {
                        let current = TerminalFontSizeValidator.effective(store.sidebarFontSize)
                        store.sidebarFontSize = current <= 9 ? 0 : current - 1
                    }
                }
            } footer: {
                Text("“Terminal Style” draws the sidebar in the terminal font "
                    + "(set under Terminal) with tight rows and text glyphs, "
                    + "so it reads like the terminal. Its font size follows "
                    + "the terminal's unless set here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("When sidebar is collapsed", selection: $sidebarSettings.collapseStyle) {
                    ForEach(SidebarCollapseStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("“Hidden” removes the sidebar entirely — bring it back with "
                    + "View ▸ Toggle Sidebar (or a shortcut bound to it under "
                    + "Keybindings).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show workspaces", isOn: $herdrPreferences.showWorkspaces)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Lets a session's sidebar row expand to show its workspaces (herdr) or "
                    + "windows (tmux) — on this machine only — and click one to switch to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show file sidebar", isOn: $fileSidebarPreferences.isVisible)
            } header: {
                Text("File sidebar")
            } footer: {
                Text("A right-hand pane showing an expandable file tree of the selected "
                    + "session's focused-pane working directory. Double-click a file to open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Show status bar", selection: $statusBarPreferences.visibility) {
                    ForEach(StatusBarVisibility.allCases, id: \.self) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
            } header: {
                Text("Status bar")
            } footer: {
                Text("A thin bar under the terminal with the focused pane's branch and its GitHub "
                    + "pull request (checks and review), via the gh CLI. Automatic shows it only "
                    + "when there is something to show; Auto-hide reveals it when the pointer "
                    + "rests at the terminal's bottom edge; Never also stops the lookups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
