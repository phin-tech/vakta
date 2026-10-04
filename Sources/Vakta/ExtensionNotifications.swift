//
//  ExtensionNotifications.swift
//  Vakta
//
//  `notify` messages from Extensions: shown through Vakta's attention path
//  only when that Extension's notifications are on, notifications are
//  allowed at all, and you aren't already looking at the Session it's about.

import Combine
import Foundation
import VaktaExtensionKit

enum ExtensionNotificationPolicy {
    static func shouldDeliver(
        extensionAllows: Bool, notificationsAllowed: Bool, isAboutSelectedSession: Bool, appActive: Bool
    ) -> Bool {
        extensionAllows && notificationsAllowed && !(isAboutSelectedSession && appActive)
    }
}

/// Routes `notify` messages to the attention notifier.
@MainActor
final class ExtensionNotifier {
    private var subscription: AnyCancellable?

    /// `sessionID(for:)` maps a Session Key to a live Session (nil when
    /// unknown); `selectedSessionID` and `appActive` are read at delivery.
    init(
        host: ExtensionHost,
        registry: ExtensionRegistryStore,
        notifier: AttentionNotifier,
        notificationsAllowed: @escaping @MainActor () -> Bool,
        selectedSessionID: @escaping @MainActor () -> UUID?,
        appActive: @escaping @MainActor () -> Bool,
        sessionID: @escaping @MainActor (SessionKey) -> UUID?
    ) {
        subscription = host.messages.sink { extensionID, message in
            guard case let .notification(ProtocolMethod.notify, params?) = message,
                  let notice = try? ExtensionProtocolCodec.decode(NotifyParams.self, from: params)
            else { return }
            let allows = registry.entries.first { $0.manifest?.id == extensionID }?.record.notifications ?? false
            let target = notice.sessionKey.flatMap(sessionID)
            let selected = selectedSessionID()
            guard ExtensionNotificationPolicy.shouldDeliver(
                extensionAllows: allows,
                notificationsAllowed: notificationsAllowed(),
                isAboutSelectedSession: target != nil && target == selected,
                appActive: appActive()
            ), let deliverTo = target ?? selected else { return }
            notifier.deliverExtensionNotice(sessionID: deliverTo, title: notice.title, body: notice.body ?? "")
        }
    }
}
