//
//  SessionBadgeStore.swift
//  Vakta
//
//  Session Badges from Extensions (`badge/set` / `badge/clear`, keyed by
//  Session Key): removed when their Extension stops, shown per row through
//  `SessionBadges.display`, and Popover rows run their first button.

import Combine
import Foundation
import VaktaExtensionKit

@MainActor
final class SessionBadgeStore: ObservableObject {
    /// The `view` name Badge Popover Callbacks carry.
    static let popoverView = "badge"

    @Published private(set) var badges: [String: [SessionKey: BadgeSetParams]] = [:]
    @Published private(set) var order: [String] = []
    var effectSink: PanelEffectSink = .inert

    private let host: ExtensionHost
    private let callbackTimeout: TimeInterval
    private var subscriptions: Set<AnyCancellable> = []

    init(host: ExtensionHost, registry: ExtensionRegistryStore, callbackTimeout: TimeInterval = 30) {
        self.host = host
        self.callbackTimeout = callbackTimeout
        registry.$entries
            .map { entries in entries.compactMap(\.manifest?.id) }
            .removeDuplicates()
            .sink { [weak self] ids in self?.order = ids }
            .store(in: &subscriptions)
        host.messages
            .sink { [weak self] extensionID, message in self?.received(message, from: extensionID) }
            .store(in: &subscriptions)
        host.stopped
            .sink { [weak self] extensionID in self?.badges[extensionID] = nil }
            .store(in: &subscriptions)
    }

    func display(for sessionKey: SessionKey) -> SessionBadgeDisplay? {
        SessionBadges.display(for: sessionKey, badges: badges, order: order)
    }

    /// Runs the first button of `itemID`'s row in that badge's Popover.
    func activate(extensionID: String, sessionKey: SessionKey, itemID: String) {
        guard case .list(let list)? = badges[extensionID]?[sessionKey]?.popover,
              let button = list.sections.lazy.flatMap(\.items).first(where: { $0.id == itemID })?.buttons.first
        else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.host.sendCallback(
                extensionID, view: Self.popoverView, button: button, form: nil, timeout: self.callbackTimeout
            )
            guard case .success(let effects) = result else { return }
            await self.effectSink.performOutsideView(EffectPlanner.plan(effects, isStale: false))
        }
    }

    private func received(_ message: JSONRPCMessage, from extensionID: String) {
        guard case let .notification(method, params?) = message else { return }
        switch method {
        case ProtocolMethod.badgeSet:
            guard let badge = try? ExtensionProtocolCodec.decode(BadgeSetParams.self, from: params) else { return }
            badges[extensionID, default: [:]][badge.sessionKey] = badge
        case ProtocolMethod.badgeClear:
            guard let clear = try? ExtensionProtocolCodec.decode(BadgeClearParams.self, from: params) else { return }
            badges[extensionID]?[clear.sessionKey] = nil
        default:
            break
        }
    }
}
