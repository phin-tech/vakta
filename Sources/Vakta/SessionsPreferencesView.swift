//
//  SessionsPreferencesView.swift
//  Vakta
//
//  The "Sessions" preferences pane: the profile a plain "New Session" uses (the
//  sidebar `+`, the menu's "New Session", and the quick create). Applies
//  immediately via `SessionStore.defaultProfileID`.

import SwiftUI

struct SessionsPreferencesView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        Form {
            Section {
                Picker("Default profile", selection: defaultProfileBinding) {
                    ForEach(sessionStore.profiles) { profile in
                        Text(profile.name.isEmpty ? "Untitled" : profile.name)
                            .tag(Optional(profile.id))
                    }
                }
            } header: {
                Text("New Sessions")
            } footer: {
                Text("Which profile the sidebar’s + button and “New Session” create "
                    + "by default. Edit the profiles themselves from the sidebar’s "
                    + "New Session ▸ menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Reflects the *effective* default (falling back to the first profile when
    /// unset) and stores the explicit choice.
    private var defaultProfileBinding: Binding<Profile.ID?> {
        Binding(
            get: { sessionStore.defaultProfileID ?? sessionStore.profiles.first?.id },
            set: { sessionStore.defaultProfileID = $0 }
        )
    }
}
