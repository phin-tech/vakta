//
//  KataServer.swift
//  kata-vakta
//
//  Routes protocol messages. Runs on the connection's serial queue.

import Foundation
import KataVaktaCore
import VaktaExtensionKit

final class KataServer {
    private let connection: Connection
    private var contexts: [ExtensionContext] = []
    private var watcher: KataEventWatcher?

    init(connection: Connection) {
        self.connection = connection
    }

    private var focused: ExtensionContext? { contexts.first(where: \.focused) }

    func handle(_ message: JSONRPCMessage) {
        switch message {
        case let .request(id, ProtocolMethod.initialize, params):
            guard let params, let decoded = try? ExtensionProtocolCodec.decode(InitializeParams.self, from: params),
                  let result = try? ExtensionProtocolCodec.encode(KataServerCore.initializeResult(for: decoded))
            else { return connection.fail(id, code: -32602, "invalid initialize params") }
            connection.respond(to: id, with: result)
        case let .notification(ProtocolMethod.contextsChanged, params):
            guard let params, let decoded = try? ExtensionProtocolCodec.decode(ContextsChangedParams.self, from: params) else { return }
            contexts = decoded.contexts
            connection.log(.debug, KataServerCore.describe(contexts))
        case let .request(id, ProtocolMethod.viewRender, params):
            guard let params, let render = try? ExtensionProtocolCodec.decode(ViewRenderParams.self, from: params) else {
                return connection.fail(id, code: -32602, "invalid view/render params")
            }
            renderView(render.view, id: id)
        case let .request(id, ProtocolMethod.shutdown, _):
            watcher?.stop()
            connection.respond(to: id, with: .null)
            exit(0)
        case let .request(id, method, _):
            connection.fail(id, code: -32601, "kata-vakta doesn't handle \(method)")
        default:
            break
        }
    }

    private func renderView(_ view: String, id: JSONRPCID) {
        guard view == KataViews.issuesViewID else { return connection.fail(id, code: -32602, "no view \(view)") }
        guard let workspace = KataViews.workspace(for: focused) else {
            return respond(id, KataViews.noFocusedSession)
        }
        switch KataCLI.issues(["list"], workspace: workspace) {
        case .notInitialized:
            watch(projectID: nil)
            respond(id, KataViews.notInitialized(directory: workspace))
        case .failed(let message):
            connection.fail(id, message)
        case .issues(let open):
            var readyIDs: Set<String> = []
            if case .issues(let ready) = KataCLI.issues(["ready"], workspace: workspace) {
                readyIDs = Set(ready.map(\.shortID))
            }
            watch(projectID: open.first?.projectID)
            respond(id, KataViews.issues(open: open, readyIDs: readyIDs))
        }
    }

    private func respond(_ id: JSONRPCID, _ document: ViewDocument) {
        guard let result = try? ExtensionProtocolCodec.encode(document) else {
            return connection.fail(id, "couldn't encode the view")
        }
        connection.respond(to: id, with: result)
    }

    /// Follows the focused project's events so the view stays live.
    private func watch(projectID: Int?) {
        guard watcher?.projectID != projectID else { return }
        watcher?.stop()
        watcher = nil
        guard let projectID else { return }
        let connection = self.connection
        let next = KataEventWatcher(projectID: projectID) {
            guard let params = try? ExtensionProtocolCodec.encode(ViewInvalidateParams(view: KataViews.issuesViewID)) else { return }
            connection.send(.notification(method: ProtocolMethod.viewInvalidate, params: params))
        }
        watcher = next
        next.start()
    }
}
