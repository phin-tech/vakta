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
            } footer: {
                Text("“Terminal Style” draws the sidebar in the terminal font "
                    + "(set under Terminal) with a prompt-style caret, so it "
                    + "reads like the terminal.")
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
        }
        .formStyle(.grouped)
    }
}
