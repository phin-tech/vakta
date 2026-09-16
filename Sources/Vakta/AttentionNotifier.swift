//
//  AttentionNotifier.swift
//  Vakta
//
//  Turns a session's agent-status *transitions* (see `SessionStore`'s poll)
//  into user-facing attention: a native notification banner and/or a Dock
//  bounce when an agent starts needing input, and a quieter banner when one
//  finishes. This is Vakta's differentiator -- "which of my agents needs me
//  right now" -- so the surfacing lives in its own small type rather than
//  buried in the store.
//
//  Two things it deliberately does NOT do:
//    * Notify on the first observation of a session (`from == nil`). On launch
//      Vakta reattaches to still-running sessions whose agents may already be
//      waiting; firing then would spam a banner per reattached agent for state
//      the user didn't just cause.
//    * Notify for the session the user is already looking at (selected + app
//      frontmost) -- there is nothing to alert them to.
//
//  Banners require `UNUserNotificationCenter`, which needs a bundle identifier
//  (present in the `.app`, absent under a bare `swift run`). When absent we
//  skip the banner and fall back to the Dock bounce, which works either way.

import AppKit
import UserNotifications

@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Set by `AppDelegate` after construction. When nil (before wiring) every
    /// flag defaults to "on".
    var settings: NotificationSettingsStore?

    /// Invoked (on the main actor) when the user clicks a notification, with
    /// the originating session's id, so the app can select and surface it.
    var onActivateSession: ((UUID) -> Void)?

    /// Banners are only possible when we have a bundle identifier.
    private var bannersAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Installs the notification-center delegate and asks for permission. Safe
    /// to call under a bundle-less `swift run` -- it just no-ops.
    func requestAuthorization() {
        guard bannersAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Reacts to one session's status change. `from == nil` is the first
    /// observation and is treated as a silent baseline.
    func handleTransition(
        sessionID: UUID,
        title: String,
        from: AgentStatus?,
        to: AgentStatus,
        isSelected: Bool,
        appActive: Bool
    ) {
        guard let from else { return } // baseline; never notify on first sight

        let notifyOnAttention = settings?.notifyOnAttention ?? true
        let notifyOnFinished = settings?.notifyOnFinished ?? true
        let bounceDock = settings?.bounceDock ?? true

        // Already looking at it -> nothing to surface.
        let alreadyFocused = isSelected && appActive

        if to == .attention, from != .attention {
            // Banner and Dock bounce are independent toggles in the prefs pane,
            // so gate them independently (both still suppressed when you're
            // already looking at the session).
            guard !alreadyFocused else { return }
            if notifyOnAttention {
                deliver(sessionID: sessionID, title: title, body: "Needs your attention", sound: true)
            }
            if bounceDock {
                NSApp.requestUserAttention(.criticalRequest)
            }
        } else if to == .idle, from == .working {
            guard notifyOnFinished, !alreadyFocused else { return }
            deliver(sessionID: sessionID, title: title, body: "Agent finished", sound: false)
        }
    }

    private func deliver(sessionID: UUID, title: String, body: String, sound: Bool) {
        guard bannersAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.userInfo = ["sessionID": sessionID.uuidString]
        // Distinct id per (session, event kind) so a "finished" doesn't replace
        // a pending "needs attention", but repeats of the same event coalesce.
        let request = UNNotificationRequest(
            identifier: "\(sessionID.uuidString):\(body)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate
    //
    // These fire on an arbitrary queue, hence `nonisolated`; they hop to the
    // main actor before touching any app state.

    /// Show the banner even while Vakta is frontmost -- the whole point is
    /// alerting you to a *different* session than the one you're in.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clicking a banner selects its session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let idString = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            if let idString, let uuid = UUID(uuidString: idString) {
                self.onActivateSession?(uuid)
            }
            completionHandler()
        }
    }
}
