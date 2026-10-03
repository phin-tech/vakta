//
//  PanelViewStore.swift
//  Vakta
//
//  The Extension Panel View on screen in the right-hand panel: renders it
//  through the Extension host, re-renders when the focused Session's context
//  changes or the Extension asks (`view/invalidate`), applies pushed
//  documents (`view/update`), and shows why when the Extension isn't running.
//  State decisions live in `PanelViewModel`.

import Combine
import Foundation
import VaktaExtensionKit

/// Where the panel's Effects that leave the panel go. Production opens URLs
/// with NSWorkspace, notifies through the attention notifier, and launches
/// panes/sessions; tests record them.
struct PanelEffectSink {
    var openURL: (URL) -> Void
    var notify: (_ title: String, _ body: String?) -> Void
    /// Returns an error message when the launch couldn't happen.
    var openPane: (_ cwd: String?, _ command: [String], _ title: String?) -> String?
    var openSession: (_ cwd: String?, _ command: [String], _ title: String?) -> String?

    static let inert = PanelEffectSink(
        openURL: { _ in }, notify: { _, _ in },
        openPane: { _, _, _ in "Vakta can't open panes yet." },
        openSession: { _, _, _ in "Vakta can't open sessions yet." }
    )
}

@MainActor
final class PanelViewStore: ObservableObject {
    @Published private(set) var model = PanelViewModel()
    @Published private(set) var active: PanelViewRef?
    @Published private(set) var callbacks = CallbackTracker()
    /// A short confirmation from a `toast` Effect; cleared after a moment.
    @Published private(set) var toast: String?

    var effectSink: PanelEffectSink = .inert

    private let host: ExtensionHost
    private var subscriptions: Set<AnyCancellable> = []

    private let callbackTimeout: TimeInterval
    private var toastGeneration = 0

    init(host: ExtensionHost, callbackTimeout: TimeInterval = 30) {
        self.host = host
        self.callbackTimeout = callbackTimeout
        host.$focusedContext
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.active != nil else { return }
                self.model.reset()
                self.render()
            }
            .store(in: &subscriptions)
        host.$phases
            .sink { [weak self] phases in self?.phasesChanged(phases) }
            .store(in: &subscriptions)
        host.messages
            .sink { [weak self] extensionID, message in self?.received(message, from: extensionID) }
            .store(in: &subscriptions)
    }

    /// Shows `ref` (or no Extension view when `nil`).
    func activate(_ ref: PanelViewRef?) {
        guard ref != active else { return }
        active = ref
        model.reset()
        callbacks = CallbackTracker()
        guard ref != nil else { return }
        if let unavailable = unavailableMessage(for: host.phases) {
            model.markUnavailable(unavailable)
        } else {
            render()
        }
    }

    func refresh() {
        render()
    }

    func callbackState(_ button: ViewButton) -> CallbackTracker.State {
        guard let view = active?.viewID else { return .idle }
        return callbacks.state(CallbackKey(view: view, button: button))
    }

    /// Sends the button's Callback and carries out the Effects it returns.
    /// Confirmation (if the button asks for it) happens before this.
    func press(_ button: ViewButton, form: [String: JSONValue]? = nil) {
        guard let ref = active else { return }
        let key = CallbackKey(view: ref.viewID, button: button)
        guard callbacks.begin(key) else { return }
        let generation = model.generation
        let params = CallbackParams(view: ref.viewID, callback: button.callback, payload: button.payload, form: form)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.host.request(
                    ref.extensionID, method: ProtocolMethod.callback,
                    params: try ExtensionProtocolCodec.encode(params), timeout: self.callbackTimeout
                )
                let decoded = try ExtensionProtocolCodec.decode(CallbackResult.self, from: result)
                self.callbacks.succeed(key)
                let isStale = self.active != ref || self.model.generation != generation
                self.perform(EffectPlanner.plan(decoded.effects, isStale: isStale), key: key)
            } catch ExtensionRequestError.rejected(let error) {
                self.callbacks.fail(key, error.message)
            } catch ExtensionRequestError.timedOut {
                self.callbacks.fail(key, "The extension didn't answer in time.")
            } catch ExtensionRequestError.notRunning, ExtensionRequestError.interrupted {
                self.callbacks.fail(key, "The extension isn't running.")
            } catch {
                self.callbacks.fail(key, "The extension's answer couldn't be read.")
            }
        }
    }

    private func perform(_ actions: [PanelAction], key: CallbackKey) {
        for action in actions {
            switch action {
            case .refresh: render()
            case .replace(let document): model.replaceVisible(document)
            case .push(let document): model.push(document)
            case .pop: model.back()
            case .toast(let text): show(toast: text)
            case let .notify(title, body): effectSink.notify(title, body)
            case .openURL(let url): effectSink.openURL(url)
            case let .openPane(cwd, command, title):
                if let failure = effectSink.openPane(cwd, command, title) { callbacks.fail(key, failure) }
            case let .openSession(cwd, command, title):
                if let failure = effectSink.openSession(cwd, command, title) { callbacks.fail(key, failure) }
            }
        }
    }

    private func show(toast text: String) {
        toastGeneration += 1
        let current = toastGeneration
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.toastGeneration == current else { return }
            self.toast = nil
        }
    }

    func setFilter(_ filter: String) { model.filter = filter }
    func select(_ itemID: String?) { model.select(itemID) }
    func openDetail(_ itemID: String) { model.openDetail(itemID) }
    func back() { model.back() }

    // MARK: - Private

    private func render() {
        guard let ref = active else { return }
        let generation = model.beginRender()
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.host.request(
                    ref.extensionID, method: ProtocolMethod.viewRender,
                    params: try ExtensionProtocolCodec.encode(ViewRenderParams(view: ref.viewID))
                )
                guard self.active == ref else { return }
                do {
                    if self.model.apply(try ExtensionProtocolCodec.decode(ViewDocument.self, from: result), generation: generation) {
                        self.callbacks.clearFailures()
                    }
                } catch {
                    self.model.fail("The extension sent a view Vakta can't read.", generation: generation)
                }
            } catch ExtensionRequestError.notRunning {
                // Starting or restarting: `phasesChanged` renders once it runs,
                // or marks the view unavailable if it can't.
                if self.active == ref, let message = self.unavailableMessage(for: self.host.phases) {
                    self.model.markUnavailable(message)
                }
            } catch ExtensionRequestError.rejected(let error) {
                guard self.active == ref else { return }
                self.model.fail(error.message, generation: generation)
            } catch ExtensionRequestError.timedOut {
                guard self.active == ref else { return }
                self.model.fail("The extension didn't answer in time.", generation: generation)
            } catch {
                // Interrupted: the phase change that interrupted it handles the view.
            }
        }
    }

    private var lastPhase: ExtensionSupervisor.Phase?

    private func phasesChanged(_ phases: [String: ExtensionSupervisor.Phase]) {
        guard let ref = active else { return }
        let phase = phases[ref.extensionID]
        defer { lastPhase = phase }
        guard phase != lastPhase else { return }
        if phase == .running {
            render()
        } else if let message = unavailableMessage(for: phases) {
            model.markUnavailable(message)
        }
    }

    /// Why the active view can't render now, or `nil` while it's running or
    /// on its way (starting, restarting).
    private func unavailableMessage(for phases: [String: ExtensionSupervisor.Phase]) -> String? {
        guard let ref = active else { return nil }
        switch phases[ref.extensionID] {
        case nil, .stopped?, .stopping?: return "The extension isn't running."
        case .failed(let reason)?: return ExtensionText.failure(reason)
        case .starting?, .initializing?, .backingOff?, .running?: return nil
        }
    }

    private func received(_ message: JSONRPCMessage, from extensionID: String) {
        guard let ref = active, ref.extensionID == extensionID, case let .notification(method, params?) = message else { return }
        switch method {
        case ProtocolMethod.viewUpdate:
            guard let update = try? ExtensionProtocolCodec.decode(ViewUpdateParams.self, from: params),
                  update.view == ref.viewID else { return }
            model.apply(update.document, generation: model.generation)
        case ProtocolMethod.viewInvalidate:
            guard let invalidate = try? ExtensionProtocolCodec.decode(ViewInvalidateParams.self, from: params),
                  invalidate.view == ref.viewID else { return }
            render()
        default:
            break
        }
    }
}
