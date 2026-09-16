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
    @EnvironmentObject private var notifier: AttentionNotifier
    @EnvironmentObject private var unreadTracking: UnreadTrackingSettingsStore

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

            Section {
                Toggle("Needs attention", isOn: $unreadTracking.trackAttention)
                Toggle("Done", isOn: $unreadTracking.trackDone)
                Toggle("Working", isOn: $unreadTracking.trackWorking)
                Toggle("Idle", isOn: $unreadTracking.trackIdle)
            } header: {
                Text("Sidebar Bell")
            } footer: {
                Text("Which status changes show up in the sidebar bell's popover "
                    + "and count toward its badge. Independent of the banner/Dock "
                    + "settings above -- the bell tracks even when banners are off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = problemMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A denied/failed authorization or delivery, otherwise invisible --
    /// previously both were silently discarded.
    private var problemMessage: String? {
        switch notifier.lastProblem {
        case nil:
            return nil
        case .authorizationDenied:
            return "Notification banners are off in System Settings for Vakta. "
                + "The Dock badge and bounce still work without them."
        case .authorizationError(let description):
            return "Couldn't ask for notification permission: \(description)"
        case .deliveryError(let description):
            return "A notification failed to deliver: \(description)"
        }
    }
}
