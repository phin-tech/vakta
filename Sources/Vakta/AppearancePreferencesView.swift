//
//  AppearancePreferencesView.swift
//  Vakta
//
//  The "Appearance" preferences pane: pick the app's window/sidebar chrome
//  theme. Applies immediately (via `AppearanceStore.didSet`); no Save/Cancel.

import SwiftUI

struct AppearancePreferencesView: View {
    @EnvironmentObject private var store: AppearanceStore

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
        }
        .formStyle(.grouped)
    }
}
