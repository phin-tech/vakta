//
//  KataServer.swift
//  kata-vakta
//
//  The Kata Extension's handlers on VaktaExtensionServer: the Issues view,
//  the Status Item, Session Badges and every Callback. Runs on the server's
//  serial queue.

import Foundation
import KataVaktaCore
import VaktaExtensionKit
import VaktaExtensionServer

/// `@unchecked Sendable`: every method runs on `server.queue` (messages,
/// `server.after` timers, and watcher callbacks hopping there with
/// `queue.async`), so its state is never touched concurrently.
final class KataServer: @unchecked Sendable {
    private let server: ExtensionServer
    private var watcher: KataEventWatcher?
    private var cache = KataQueryCache()
    private let daemon = KataDaemonClient()
    private var badgeGeneration = 0

    init(server: ExtensionServer) {
        self.server = server
        // Find the daemon now, so the first query doesn't pay for it.
        server.onReady = { [unowned self] in daemon.warm() }
        server.onContexts = { [unowned self] previous, current in
            server.log(.debug, KataServerCore.describe(current))
            if KataViews.workspace(for: current.first(where: \.focused)) != KataViews.workspace(for: previous.first(where: \.focused)) {
                refreshStatus()
            }
            scheduleBadges()
        }
        server.onShutdown = { [unowned self] in watcher?.stop() }
        server.onRender(KataViews.issuesViewID) { [unowned self] in try renderIssues() }
        registerCallbacks()
    }

    private var focused: ExtensionContext? { server.focusedContext }

    // MARK: - Issues view and Status Item

    private func renderIssues() throws -> ViewDocument {
        guard let workspace = KataViews.workspace(for: focused) else { return KataViews.noFocusedSession }
        switch load(workspace) {
        case .notInitialized: return KataViews.notInitialized(directory: workspace)
        case .failed(let message): throw ExtensionError(message)
        case let .loaded(open, readyIDs): return KataViews.issues(open: open, readyIDs: readyIDs)
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
        switch query(workspace) {
        case .success(.notInitialized):
            watch(projectID: nil)
            server.setStatus(nil)
            return .notInitialized
        case .success(.loaded(let open, let readyIDs)):
            watch(projectID: open.first?.projectID)
            server.setStatus(KataViews.status(open: open, readyIDs: readyIDs))
            return .loaded(open: open, readyIDs: readyIDs)
        case .failure(let failure):
            return .failed(failure.message)
        }
    }

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
    private func refreshStatus() {
        guard let workspace = KataViews.workspace(for: focused) else {
            watch(projectID: nil)
            return server.setStatus(nil)
        }
        _ = load(workspace)
    }

    // MARK: - Session Badges

    /// Badges can query every Session's repository; doing that before the
    /// render request that follows a focus switch would delay the panel.
    /// Refresh shortly after the burst instead.
    private func scheduleBadges() {
        badgeGeneration += 1
        let generation = badgeGeneration
        server.after(0.3) { [weak self] in
            guard let self, self.badgeGeneration == generation else { return }
            self.refreshBadges()
        }
    }

    /// Badges every Session working on an open issue of its own repository.
    private func refreshBadges() {
        let map = KataStorage.sessions()
        var openByWorkspace: [String: [KataIssue]] = [:]
        var next: [SessionKey: BadgeSetParams] = [:]
        for context in server.contexts {
            guard let workspace = KataViews.workspace(for: context) else { continue }
            if openByWorkspace[workspace] == nil {
                if case .success(.loaded(let open, _)) = query(workspace) { openByWorkspace[workspace] = open } else { openByWorkspace[workspace] = [] }
            }
            let open = openByWorkspace[workspace] ?? []
            guard let id = KataBadges.issueID(
                branch: context.branch, sessionKey: context.sessionKey, map: map, openIDs: Set(open.map(\.shortID))
            ), let issue = open.first(where: { $0.shortID == id }) else { continue }
            next[context.sessionKey] = KataBadges.badge(for: issue, sessionKey: context.sessionKey)
        }
        server.setBadges(next)
    }

    // MARK: - Callbacks

    private func workspace() throws -> String {
        guard let workspace = KataViews.workspace(for: focused) else { throw ExtensionError("No focused session.") }
        return workspace
    }

    private func issue(_ callback: CallbackParams) throws -> String {
        guard let issue = KataCallbacks.issueID(callback.payload) else { throw ExtensionError.invalidParams("missing issue id") }
        return issue
    }

    /// Anything a Callback did may have changed issues; the refresh that
    /// usually follows must not read the cache.
    private func done(_ effects: [Effect]) -> [Effect] {
        cache.invalidateAll()
        return effects
    }

    private func registerCallbacks() {
        server.onCallback(KataCallbacks.claim) { [unowned self] callback in
            let issue = try issue(callback)
            if let failure = KataCLI.mutate(["claim", issue, "--if-unowned"], workspace: try workspace()) { throw ExtensionError(failure) }
            return done(KataCallbacks.claimed(issue))
        }
        server.onCallback(KataStart.callback) { [unowned self] callback in
            let issue = try issue(callback), workspace = try workspace()
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
            scheduleBadges()
            return done(KataStart.effects(id: issue, workspace: workspace, command: command))
        }
        for name in [KataForms.commentForm, KataForms.closeForm] {
            server.onCallback(name) { [unowned self] callback in
                let issue = try issue(callback)
                return [.push(name == KataForms.commentForm ? KataForms.comment(issue: issue) : KataForms.close(issue: issue))]
            }
        }
        server.onCallback(KataForms.newForm) { _ in [.push(KataForms.newIssue())] }
        for name in [KataForms.commentSubmit, KataForms.closeSubmit, KataForms.newSubmit] {
            server.onCallback(name) { [unowned self] callback in
                switch KataForms.arguments(for: name, issue: KataCallbacks.issueID(callback.payload), values: callback.form ?? [:]) {
                case .failure(.missing(let field)):
                    throw ExtensionError.invalidParams("Missing \(field).")
                case .failure(.unknownForm):
                    throw ExtensionError("unknown form", code: -32601)
                case .success(let arguments):
                    switch KataCLI.mutateReturningOutput(arguments, workspace: try workspace()) {
                    case .failure(let failure): throw ExtensionError(failure.text)
                    case .success(let output): return done(KataForms.effects(after: name, created: KataForms.createdID(output)))
                    }
                }
            }
        }
    }

    // MARK: - Live updates

    /// Follows the focused project's events so the view stays live.
    private func watch(projectID: Int?) {
        guard watcher?.projectID != projectID else { return }
        watcher?.stop()
        watcher = nil
        guard let projectID else { return }
        let queue = server.queue
        let next = KataEventWatcher(projectID: projectID) { [weak self] in
            queue.async {
                guard let self else { return }
                // Clear first, so the re-render the invalidation causes reads fresh data.
                self.cache.invalidate(projectID: projectID)
                self.server.invalidate(view: KataViews.issuesViewID)
                self.refreshStatus()
                self.refreshBadges()
            }
        }
        watcher = next
        next.start()
    }
}
