//
//  NotificationsPreferencesView.swift
//  Vakta
//
//  The "Notifications" preferences pane: whether Vakta alerts you as an agent
//  starts needing input or finishes, and whether it bounces the Dock. Applies
//  immediately (each `NotificationSettingsStore` flag persists on change).

import SwiftUI

struct NotificationsPreferencesView: View {
    @EnvironmentObject private var store: NotificationSettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("When an agent needs attention", isOn: $store.notifyOnAttention)
                Toggle("When an agent finishes", isOn: $store.notifyOnFinished)
            } footer: {
                Text("Vakta notifies you about sessions other than the one you're "
                    + "currently viewing, so you know which agent to switch to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Bounce the Dock icon for attention", isOn: $store.bounceDock)
            } footer: {
                Text("The Dock badge always shows how many sessions are waiting on "
                    + "you. Banners require the packaged app (a plain `swift run` "
                    + "build has no bundle identifier).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
