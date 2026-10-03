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
            let previous = KataViews.workspace(for: focused)
            contexts = decoded.contexts
            connection.log(.debug, KataServerCore.describe(contexts))
            if KataViews.workspace(for: focused) != previous { refreshStatus() }
            refreshBadges()
        case let .request(id, ProtocolMethod.viewRender, params):
            guard let params, let render = try? ExtensionProtocolCodec.decode(ViewRenderParams.self, from: params) else {
                return connection.fail(id, code: -32602, "invalid view/render params")
            }
            renderView(render.view, id: id)
        case let .request(id, ProtocolMethod.callback, params):
            guard let params, let callback = try? ExtensionProtocolCodec.decode(CallbackParams.self, from: params) else {
                return connection.fail(id, code: -32602, "invalid callback params")
            }
            handleCallback(callback, id: id)
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
        switch load(workspace) {
        case .notInitialized:
            respond(id, KataViews.notInitialized(directory: workspace))
        case .failed(let message):
            connection.fail(id, message)
        case let .loaded(open, readyIDs):
            respond(id, KataViews.issues(open: open, readyIDs: readyIDs))
        }
    }

    private enum Loaded {
        case loaded(open: [KataIssue], readyIDs: Set<String>)
        case notInitialized
        case failed(String)
    }

    /// Open and ready issues for `workspace`; also points the event watcher
    /// at its project and refreshes the Status Item.
    private func load(_ workspace: String) -> Loaded {
        switch KataCLI.issues(["list"], workspace: workspace) {
        case .notInitialized:
            watch(projectID: nil)
            sendStatus(nil)
            return .notInitialized
        case .failed(let message):
            return .failed(message)
        case .issues(let open):
            var readyIDs: Set<String> = []
            if case .issues(let ready) = KataCLI.issues(["ready"], workspace: workspace) {
                readyIDs = Set(ready.map(\.shortID))
            }
            watch(projectID: open.first?.projectID)
            sendStatus(KataViews.status(open: open, readyIDs: readyIDs))
            return .loaded(open: open, readyIDs: readyIDs)
        }
    }

    /// Recomputes the Status Item for the focused workspace.
    func refreshStatus() {
        guard let workspace = KataViews.workspace(for: focused) else {
            watch(projectID: nil)
            return sendStatus(nil)
        }
        _ = load(workspace)
    }

    private var badges: [SessionKey: BadgeSetParams] = [:]

    /// Badges every Session working on an open issue of its own repository.
    func refreshBadges() {
        let map = KataStorage.sessions()
        var openByWorkspace: [String: [KataIssue]] = [:]
        var next: [SessionKey: BadgeSetParams] = [:]
        for context in contexts {
            guard let workspace = KataViews.workspace(for: context) else { continue }
            if openByWorkspace[workspace] == nil {
                if case .issues(let open) = KataCLI.issues(["list"], workspace: workspace) {
                    openByWorkspace[workspace] = open
                } else {
                    openByWorkspace[workspace] = []
                }
            }
            let open = openByWorkspace[workspace] ?? []
            guard let id = KataBadges.issueID(
                branch: context.branch, sessionKey: context.sessionKey, map: map, openIDs: Set(open.map(\.shortID))
            ), let issue = open.first(where: { $0.shortID == id }) else { continue }
            next[context.sessionKey] = KataBadges.badge(for: issue, sessionKey: context.sessionKey)
        }
        for message in KataBadges.changes(from: badges, to: next) { connection.send(message) }
        badges = next
    }

    private var lastStatus: StatusSetParams??

    private func sendStatus(_ status: StatusSetParams?) {
        guard lastStatus != .some(status) else { return }
        lastStatus = .some(status)
        if let status, let params = try? ExtensionProtocolCodec.encode(status) {
            connection.send(.notification(method: ProtocolMethod.statusSet, params: params))
        } else {
            connection.send(.notification(method: ProtocolMethod.statusClear, params: nil))
        }
    }

    private func handleCallback(_ callback: CallbackParams, id: JSONRPCID) {
        guard let workspace = KataViews.workspace(for: focused) else {
            return connection.fail(id, "No focused session.")
        }
        switch callback.callback {
        case KataCallbacks.claim:
            guard let issue = KataCallbacks.issueID(callback.payload) else { return connection.fail(id, code: -32602, "missing issue id") }
            if let failure = KataCLI.mutate(["claim", issue, "--if-unowned"], workspace: workspace) {
                return connection.fail(id, failure)
            }
            respond(id, effects: KataCallbacks.claimed(issue))
        case KataStart.callback:
            guard let issue = KataCallbacks.issueID(callback.payload) else { return connection.fail(id, code: -32602, "missing issue id") }
            var title = issue
            if case .object(let fields)? = callback.payload, case .string(let given)? = fields["title"] { title = given }
            // Claim it if nobody has; already owned (by anyone) is fine.
            _ = KataCLI.mutate(["claim", issue, "--if-unowned"], workspace: workspace)
            if let session = focused?.sessionKey {
                var map = KataStorage.sessions()
                map.record(issue, for: session)
                KataStorage.save(map)
            }
            let command = KataStart.command(template: KataStorage.config().agentCommand, id: issue, title: title)
            respond(id, effects: KataStart.effects(id: issue, workspace: workspace, command: command))
            refreshBadges()
        case KataForms.commentForm, KataForms.closeForm:
            guard let issue = KataCallbacks.issueID(callback.payload) else { return connection.fail(id, code: -32602, "missing issue id") }
            let form = callback.callback == KataForms.commentForm ? KataForms.comment(issue: issue) : KataForms.close(issue: issue)
            respond(id, effects: [.push(form)])
        case KataForms.newForm:
            respond(id, effects: [.push(KataForms.newIssue())])
        case KataForms.commentSubmit, KataForms.closeSubmit, KataForms.newSubmit:
            let issue = KataCallbacks.issueID(callback.payload)
            switch KataForms.arguments(for: callback.callback, issue: issue, values: callback.form ?? [:]) {
            case .failure(.missing(let field)):
                connection.fail(id, code: -32602, "Missing \(field).")
            case .failure(.unknownForm):
                connection.fail(id, code: -32601, "unknown form")
            case .success(let arguments):
                switch KataCLI.mutateReturningOutput(arguments, workspace: workspace) {
                case .failure(let failure):
                    connection.fail(id, failure.text)
                case .success(let output):
                    respond(id, effects: KataForms.effects(after: callback.callback, created: KataForms.createdID(output)))
                }
            }
        default:
            connection.fail(id, code: -32601, "unknown action \(callback.callback)")
        }
    }

    private func respond(_ id: JSONRPCID, effects: [Effect]) {
        guard let result = try? ExtensionProtocolCodec.encode(CallbackResult(effects: effects)) else {
            return connection.fail(id, "couldn't encode the result")
        }
        connection.respond(to: id, with: result)
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
        let next = KataEventWatcher(projectID: projectID) { [weak self] in
            guard let params = try? ExtensionProtocolCodec.encode(ViewInvalidateParams(view: KataViews.issuesViewID)) else { return }
            connection.send(.notification(method: ProtocolMethod.viewInvalidate, params: params))
            connection.queue.async {
                self?.refreshStatus()
                self?.refreshBadges()
            }
        }
        watcher = next
        next.start()
    }
}
