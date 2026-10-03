//
//  KataServer.swift
//  kata-vakta
//
//  Routes protocol messages. Runs on the connection's serial queue.

import Foundation
import KataVaktaCore
import VaktaExtensionKit

/// `@unchecked Sendable`: every method runs on `Connection.queue` (a serial
/// queue) -- messages via `Connection.run`, watcher callbacks via
/// `connection.queue.async` -- so its state is never touched concurrently.
final class KataServer: @unchecked Sendable {
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
            // Find the daemon now, so the first query doesn't pay for it.
            daemon.warm()
        case let .notification(ProtocolMethod.contextsChanged, params):
            guard let params, let decoded = try? ExtensionProtocolCodec.decode(ContextsChangedParams.self, from: params) else { return }
            let previous = KataViews.workspace(for: focused)
            contexts = decoded.contexts
            connection.log(.debug, KataServerCore.describe(contexts))
            if KataViews.workspace(for: focused) != previous { refreshStatus() }
            scheduleBadges()
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
    private func load(_ workspace: String, updatingFocus: Bool = true) -> Loaded {
        let result: Loaded
        switch query(workspace) {
        case .success(.notInitialized): result = .notInitialized
        case .success(.loaded(let open, let readyIDs)): result = .loaded(open: open, readyIDs: readyIDs)
        case .failure(let failure): return .failed(failure.message)
        }
        guard updatingFocus else { return result }
        switch result {
        case .notInitialized:
            watch(projectID: nil)
            sendStatus(nil)
        case let .loaded(open, readyIDs):
            watch(projectID: open.first?.projectID)
            sendStatus(KataViews.status(open: open, readyIDs: readyIDs))
        case .failed:
            break
        }
        return result
    }

    private var cache = KataQueryCache()
    private let daemon = KataDaemonClient()

    private struct QueryFailure: Error { let message: String }

    /// Open and ready issues for `workspace`, from the cache when fresh.
    private func query(_ workspace: String) -> Result<KataQueryCache.Value, QueryFailure> {
        if let cached = cache.value(for: workspace, at: Date()) { return .success(cached) }
        // The daemon socket is the fast path; the CLI is the fallback.
        if let direct = daemon.query(workspace) {
            cache.store(direct, for: workspace, at: Date())
            return .success(direct)
        }
        // `list` and `ready` are independent: run them side by side.
        var ready: KataOutput = .issues([])
        let readyDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ready = KataCLI.issues(["ready"], workspace: workspace)
            readyDone.signal()
        }
        let list = KataCLI.issues(["list"], workspace: workspace)
        readyDone.wait()
        let value: KataQueryCache.Value
        switch list {
        case .notInitialized:
            value = .notInitialized
        case .failed(let message):
            return .failure(QueryFailure(message: message))
        case .issues(let open):
            var readyIDs: Set<String> = []
            if case .issues(let readyIssues) = ready { readyIDs = Set(readyIssues.map(\.shortID)) }
            value = .loaded(open: open, readyIDs: readyIDs)
        }
        cache.store(value, for: workspace, at: Date())
        return .success(value)
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
    private var badgeGeneration = 0

    /// Badges can query every Session's repository; doing that before the
    /// render request that follows a focus switch would delay the panel.
    /// Refresh shortly after the burst instead.
    private func scheduleBadges() {
        badgeGeneration += 1
        let generation = badgeGeneration
        connection.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.badgeGeneration == generation else { return }
            self.refreshBadges()
        }
    }

    /// Badges every Session working on an open issue of its own repository.
    func refreshBadges() {
        let map = KataStorage.sessions()
        var openByWorkspace: [String: [KataIssue]] = [:]
        var next: [SessionKey: BadgeSetParams] = [:]
        for context in contexts {
            guard let workspace = KataViews.workspace(for: context) else { continue }
            if openByWorkspace[workspace] == nil {
                if case .success(.loaded(let open, _)) = query(workspace) {
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
        // Anything a Callback did may have changed issues; the refresh that
        // usually follows must not read the cache.
        cache.invalidateAll()
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
            connection.queue.async {
                // Clear first, so the re-render the invalidation causes reads fresh data.
                self?.cache.invalidate(projectID: projectID)
                connection.send(.notification(method: ProtocolMethod.viewInvalidate, params: params))
                self?.refreshStatus()
                self?.refreshBadges()
            }
        }
        watcher = next
        next.start()
    }
}
