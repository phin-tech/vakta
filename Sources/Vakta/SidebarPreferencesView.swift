//
//  SidebarPreferencesView.swift
//  Vakta
//
//  The "Sidebar" preferences pane: choose what collapsing the sidebar does --
//  shrink to an icon rail, or hide it completely. Applies immediately.

import SwiftUI

struct SidebarPreferencesView: View {
    @EnvironmentObject private var store: SidebarSettingsStore

    var body: some View {
        Form {
            Section {
                Picker("When collapsed", selection: $store.collapseStyle) {
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
