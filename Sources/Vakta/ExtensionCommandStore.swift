//
//  ExtensionCommandStore.swift
//  Vakta
//
//  ⌘K Commands from Extensions: each `commands/set` replaces that
//  Extension's list, an Extension's Commands vanish when it stops, entries
//  follow link order, and choosing one sends its Callback. Like Popovers,
//  only Effects that leave the palette apply (URLs, notifications, launches).

import Combine
import Foundation
import VaktaExtensionKit

@MainActor
final class ExtensionCommandStore: ObservableObject {
    /// The `view` name Command Callbacks carry.
    static let callbackView = "command"

    @Published private(set) var entries: [PaletteItemAssembler.ExtensionCommandEntry] = []
    var effectSink: PanelEffectSink = .inert

    private let host: ExtensionHost
    private let callbackTimeout: TimeInterval
    private var commands: [String: [ExtensionCommand]] = [:] { didSet { rebuild() } }
    private var order: [(id: String, name: String)] = [] { didSet { rebuild() } }
    private var subscriptions: Set<AnyCancellable> = []

    init(host: ExtensionHost, registry: ExtensionRegistryStore, callbackTimeout: TimeInterval = 30) {
        self.host = host
        self.callbackTimeout = callbackTimeout
        registry.$entries
            .sink { [weak self] entries in
                self?.order = entries.compactMap { entry in entry.manifest.map { (id: $0.id, name: $0.name) } }
            }
            .store(in: &subscriptions)
        host.messages
            .sink { [weak self] extensionID, message in
                guard case let .notification(ProtocolMethod.commandsSet, params?) = message,
                      let set = try? ExtensionProtocolCodec.decode(CommandsSetParams.self, from: params)
                else { return }
                self?.commands[extensionID] = set.commands
            }
            .store(in: &subscriptions)
        host.stopped
            .sink { [weak self] extensionID in self?.commands[extensionID] = nil }
            .store(in: &subscriptions)
    }

    func run(extensionID: String, commandID: String) {
        guard let command = commands[extensionID]?.first(where: { $0.id == commandID }) else { return }
        let button = ViewButton(
            title: command.title, symbol: command.symbol, callback: command.callback, payload: command.payload,
            style: .default, confirm: nil, shortcut: nil
        )
        Task { [weak self] in
            guard let self else { return }
            let result = await self.host.sendCallback(
                extensionID, view: Self.callbackView, button: button, form: nil, timeout: self.callbackTimeout
            )
            guard case .success(let effects) = result else { return }
            await self.effectSink.performOutsideView(EffectPlanner.plan(effects, isStale: false))
        }
    }

    private func rebuild() {
        let next = order.flatMap { owner in
            (commands[owner.id] ?? []).map {
                PaletteItemAssembler.ExtensionCommandEntry(extensionID: owner.id, extensionName: owner.name, id: $0.id, title: $0.title)
            }
        }
        if next != entries { entries = next }
    }
}
