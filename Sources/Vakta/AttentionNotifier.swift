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
//  The *decision* of what a transition should cause lives in the pure
//  `AttentionTransitionPolicy`; this type is the shell around it -- OS
//  notification delivery (behind the injectable `NotificationDelivering`,
//  so the decision-to-delivery wiring is testable with an in-memory fake)
//  and the Dock bounce.
//
//  Banners require `UNUserNotificationCenter`, which needs a bundle identifier
//  (present in the `.app`, absent under a bare `swift run`). When absent we
//  skip the banner and fall back to the Dock bounce, which works either way.

import AppKit
import UserNotifications

/// A denied/failed authorization or delivery -- previously both were
/// silently discarded (`requestAuthorization`'s completion ignored both
/// arguments; `deliver`'s `add(_:)` call had no completion handler at all).
enum NotificationDeliveryProblem: Equatable {
    case authorizationDenied
    case authorizationError(String)
    case deliveryError(String)
}

/// Abstraction over actual OS notification delivery, so `AttentionNotifier`'s
/// decision-to-delivery wiring is testable with an in-memory fake instead of
/// a real `UNUserNotificationCenter` (which needs a bundle identifier and
/// system permission -- unavailable in a headless test).
protocol NotificationDelivering {
    /// Registers `delegate` for click/foreground-presentation callbacks.
    /// Part of this abstraction (not a direct `UNUserNotificationCenter`
    /// touch in `AttentionNotifier`) so a fake never has to construct a real
    /// notification center, which by itself throws outside a proper app
    /// bundle context (e.g. under `swift test`).
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate)
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void)
    func deliver(sessionID: UUID, title: String, body: String, sound: Bool, completion: @escaping (Error?) -> Void)
}

final class SystemNotificationDelivery: NotificationDelivering {
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        UNUserNotificationCenter.current().delegate = delegate
    }

    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound], completionHandler: completion)
    }

    func deliver(sessionID: UUID, title: String, body: String, sound: Bool, completion: @escaping (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.userInfo = ["sessionID": sessionID.uuidString]
        // Distinct id per (session, event kind) so a "finished" doesn't
        // replace a pending "needs attention", but repeats of the same
        // event coalesce.
        let request = UNNotificationRequest(
            identifier: "\(sessionID.uuidString):\(body)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }
}

@MainActor
final class AttentionNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Set by `AppDelegate` after construction. When nil (before wiring) every
    /// flag defaults to "on".
    var settings: NotificationSettingsStore?

    /// Invoked (on the main actor) when the user clicks a notification, with
    /// the originating session's id, so the app can select and surface it.
    var onActivateSession: ((UUID) -> Void)?

    /// The most recent authorization/delivery problem, or nil once a
    /// request/delivery has succeeded. Surfaced in the Notifications
    /// preferences pane.
    @Published private(set) var lastProblem: NotificationDeliveryProblem?

    private let delivery: NotificationDelivering
    private let bounceDockAction: @MainActor () -> Void

    /// Banners are only possible when we have a bundle identifier -- true in
    /// the packaged `.app`, false under a bare `swift run`/`swift test`
    /// (neither has one). Injectable so a test can exercise the
    /// decision-to-delivery wiring against `delivery` without a real bundle;
    /// production always uses the real check.
    private let bannersAvailable: Bool

    init(
        delivery: NotificationDelivering = SystemNotificationDelivery(),
        bannersAvailable: Bool = Bundle.main.bundleIdentifier != nil,
        bounceDockAction: @escaping @MainActor () -> Void = { NSApp.requestUserAttention(.criticalRequest) }
    ) {
        self.delivery = delivery
        self.bannersAvailable = bannersAvailable
        self.bounceDockAction = bounceDockAction
    }

    /// Installs the notification-center delegate and asks for permission. Safe
    /// to call under a bundle-less `swift run` -- it just no-ops. Denial or an
    /// authorization error updates `lastProblem` rather than being discarded.
    func requestAuthorization() {
        guard bannersAvailable else { return }
        delivery.setDelegate(self)
        delivery.requestAuthorization { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastProblem = .authorizationError(error.localizedDescription)
                } else if !granted {
                    self.lastProblem = .authorizationDenied
                } else {
                    self.lastProblem = nil
                }
            }
        }
    }

    /// Reacts to one session's status change. Decision-only logic lives in
    /// `AttentionTransitionPolicy`; this just carries it out.
    func handleTransition(
        sessionID: UUID,
        title: String,
        from: AgentStatus?,
        to: AgentStatus,
        isSelected: Bool,
        appActive: Bool
    ) {
        let decision = AttentionTransitionPolicy.decide(
            from: from,
            to: to,
            isSelected: isSelected,
            appActive: appActive,
            notifyOnAttention: settings?.notifyOnAttention ?? true,
            notifyOnFinished: settings?.notifyOnFinished ?? true,
            bounceDock: settings?.bounceDock ?? true
        )

        if decision.shouldBanner, let body = decision.bannerBody {
            deliver(sessionID: sessionID, title: title, body: body, sound: decision.playSound)
        }
        if decision.shouldBounceDock {
            bounceDockAction()
        }
    }

    private func deliver(sessionID: UUID, title: String, body: String, sound: Bool) {
        guard bannersAvailable else { return }
        delivery.deliver(sessionID: sessionID, title: title, body: body, sound: sound) { [weak self] error in
            Task { @MainActor in
                // A later successful delivery clears a stale failure from an
                // earlier one -- otherwise a transient error would leave
                // `lastProblem` (and the Preferences banner reading it)
                // stuck forever even after delivery started working again.
                self?.lastProblem = error.map { .deliveryError($0.localizedDescription) }
            }
        }
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
