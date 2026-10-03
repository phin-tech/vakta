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
    var openPane: @MainActor (_ cwd: String?, _ command: [String], _ title: String?) async -> String?
    var openSession: @MainActor (_ cwd: String?, _ command: [String], _ title: String?) async -> String?

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
    /// The form on screen and its edits; replaced when another form shows.
    @Published private var currentForm: FormState?

    var effectSink: PanelEffectSink = .inert

    private let host: ExtensionHost
    private var subscriptions: Set<AnyCancellable> = []

    /// A view in one place: the focused Session's location when it rendered.
    private struct PlaceKey: Hashable {
        var ref: PanelViewRef
        var sessionKey: SessionKey?
        var cwd: String?
        var gitRoot: String?
        var branch: String?
        var workspaceID: String?
    }

    /// The last document per place, so switching back shows it at once.
    private var lastDocuments: [PlaceKey: ViewDocument] = [:]
    private static let lastDocumentsLimit = 32

    private var pendingFocusedContext: ExtensionContext??

    private func placeKey(_ ref: PanelViewRef) -> PlaceKey {
        let context = pendingFocusedContext ?? host.focusedContext
        return PlaceKey(
            ref: ref, sessionKey: context?.sessionKey, cwd: context?.cwd, gitRoot: context?.gitRoot,
            branch: context?.branch, workspaceID: context?.workspace?.id
        )
    }

    private func remember(_ document: ViewDocument) {
        guard let ref = active else { return }
        if lastDocuments.count >= Self.lastDocumentsLimit { lastDocuments.removeAll() }
        lastDocuments[placeKey(ref)] = document
    }

    /// Resets for the current place, showing its last document if known.
    private func resetForCurrentPlace() {
        if let ref = active, let cached = lastDocuments[placeKey(ref)] {
            model.reset(showing: cached)
        } else {
            model.reset()
        }
    }

    private let callbackTimeout: TimeInterval
    private var toastGeneration = 0

    init(host: ExtensionHost, callbackTimeout: TimeInterval = 30) {
        self.host = host
        self.callbackTimeout = callbackTimeout
        host.$focusedContext
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] context in
                guard let self, self.active != nil else { return }
                // `sink` runs before `focusedContext` is assigned; key on the new value.
                self.pendingFocusedContext = context
                self.resetForCurrentPlace()
                self.pendingFocusedContext = nil
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
        resetForCurrentPlace()
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
        Task { [weak self] in
            guard let self else { return }
            switch await self.host.sendCallback(ref.extensionID, view: ref.viewID, button: button, form: form, timeout: self.callbackTimeout) {
            case .success(let effects):
                self.callbacks.succeed(key)
                let isStale = self.active != ref || self.model.generation != generation
                self.perform(EffectPlanner.plan(effects, isStale: isStale), key: key)
            case .failure(let failure):
                self.callbacks.fail(key, failure.message)
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
                let open = effectSink.openPane
                Task { if let failure = await open(cwd, command, title) { self.callbacks.fail(key, failure) } }
            case let .openSession(cwd, command, title):
                let open = effectSink.openSession
                Task { if let failure = await open(cwd, command, title) { self.callbacks.fail(key, failure) } }
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

    /// The state of `form` while it's on screen (fresh when it changes).
    func formState(for form: FormView) -> FormState {
        if let current = currentForm, current.form == form { return current }
        return FormState(form: form)
    }

    func editForm(_ form: FormView, _ edit: (inout FormState) -> Void) {
        var state = formState(for: form)
        edit(&state)
        currentForm = state
    }

    /// Validates `form` and, when it passes, sends its submit Callback with
    /// the field values.
    func submitForm(_ form: FormView) {
        var state = formState(for: form)
        let values = state.submit()
        currentForm = state
        guard let values else { return }
        press(form.submit, form: values)
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
                    let document = try ExtensionProtocolCodec.decode(ViewDocument.self, from: result)
                    if self.model.apply(document, generation: generation) {
                        self.remember(document)
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
            if model.apply(update.document, generation: model.generation) { remember(update.document) }
        case ProtocolMethod.viewInvalidate:
            guard let invalidate = try? ExtensionProtocolCodec.decode(ViewInvalidateParams.self, from: params),
                  invalidate.view == ref.viewID else { return }
            render()
        default:
            break
        }
    }
}
