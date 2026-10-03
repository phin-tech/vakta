//
//  StatusItemStore.swift
//  Vakta
//
//  Extension Status Items: follows `status/set` / `status/clear`, drops an
//  Extension's item the moment it stops running, orders items by link
//  order, and runs Popover row buttons. Popovers have no navigation, so only
//  Effects that leave the popover (URLs, notifications, launches) apply.

import Combine
import Foundation
import VaktaExtensionKit

@MainActor
final class StatusItemStore: ObservableObject {
    /// The `view` name Popover Callbacks carry.
    static let popoverView = "status"

    @Published private(set) var items: [StatusBarExtensionItem] = []
    var effectSink: PanelEffectSink = .inert

    private let host: ExtensionHost
    private let callbackTimeout: TimeInterval
    private var raw: [String: StatusSetParams] = [:] { didSet { rebuild() } }
    private var order: [String] = [] { didSet { rebuild() } }
    private var subscriptions: Set<AnyCancellable> = []

    init(host: ExtensionHost, registry: ExtensionRegistryStore, callbackTimeout: TimeInterval = 30) {
        self.host = host
        self.callbackTimeout = callbackTimeout
        registry.$entries
            .map { entries in entries.compactMap(\.manifest?.id) }
            .sink { [weak self] ids in self?.order = ids }
            .store(in: &subscriptions)
        host.messages
            .sink { [weak self] extensionID, message in self?.received(message, from: extensionID) }
            .store(in: &subscriptions)
        host.stopped
            .sink { [weak self] extensionID in self?.raw[extensionID] = nil }
            .store(in: &subscriptions)
    }

    /// Runs the first button of `itemID`'s row in that Extension's Popover.
    func activate(extensionID: String, itemID: String) {
        guard case .list(let list)? = items.first(where: { $0.extensionID == extensionID })?.popover,
              let item = list.sections.lazy.flatMap(\.items).first(where: { $0.id == itemID }),
              let button = item.buttons.first
        else { return }
        press(extensionID: extensionID, button: button)
    }

    func press(extensionID: String, button: ViewButton) {
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
        guard case let .notification(method, params) = message else { return }
        switch method {
        case ProtocolMethod.statusSet:
            guard let params, let item = try? ExtensionProtocolCodec.decode(StatusSetParams.self, from: params) else { return }
            raw[extensionID] = item
        case ProtocolMethod.statusClear:
            raw[extensionID] = nil
        default:
            break
        }
    }

    private func rebuild() {
        let merged = ExtensionStatusItems.merge(raw, order: order)
        if merged != items { items = merged }
    }
}

extension PanelEffectSink {
    /// Carries out the actions that leave a Popover (it has no navigation
    /// or room for a toast); view actions are skipped.
    @MainActor
    func performOutsideView(_ actions: [PanelAction]) async {
        for action in actions {
            switch action {
            case .openURL(let url): openURL(url)
            case let .notify(title, body): notify(title, body)
            case let .openPane(cwd, command, title): _ = await openPane(cwd, command, title)
            case let .openSession(cwd, command, title): _ = await openSession(cwd, command, title)
            case .refresh, .replace, .push, .pop, .toast: break
            }
        }
    }
}
