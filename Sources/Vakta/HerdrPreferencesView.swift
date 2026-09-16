//
//  HerdrPreferencesView.swift
//  Vakta
//
//  The "Herdr" preferences pane: the one toggle gating the sidebar's
//  per-session workspace disclosure. Applies immediately via
//  `HerdrPreferencesStore`.

import SwiftUI

struct HerdrPreferencesView: View {
    @EnvironmentObject private var herdrPreferences: HerdrPreferencesStore

    var body: some View {
        Form {
            Section {
                Toggle("Show workspaces", isOn: $herdrPreferences.showWorkspaces)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Lets a herdr session's sidebar row expand to show that session's "
                    + "workspaces (on this machine only), and click one to switch to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
