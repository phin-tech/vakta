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

@MainActor
final class PanelViewStore: ObservableObject {
    @Published private(set) var model = PanelViewModel()
    @Published private(set) var active: PanelViewRef?

    private let host: ExtensionHost
    private var subscriptions: Set<AnyCancellable> = []

    init(host: ExtensionHost) {
        self.host = host
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
                    self.model.apply(try ExtensionProtocolCodec.decode(ViewDocument.self, from: result), generation: generation)
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
