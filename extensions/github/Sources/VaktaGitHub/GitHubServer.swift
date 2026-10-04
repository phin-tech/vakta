//
//  GitHubServer.swift
//  vakta-github
//
//  Routes protocol messages and keeps PR state fresh. Every method runs on
//  `Connection.queue` (serial), including the refresh timer, so state is
//  never touched concurrently (hence `@unchecked Sendable`).

import Foundation
import GitHubCore
import VaktaExtensionKit

final class GitHubServer: @unchecked Sendable {
    let connection: Connection
    private let api = GitHubAPI()
    private var contexts: [ExtensionContext] = []

    /// Resolved PR targets per pane id.
    private(set) var targetsByPane: [String: PullRequestTarget] = [:]
    /// Latest result per target (nil: confirmed no open PR).
    private(set) var pullRequests: [PullRequestTarget: PullRequest?] = [:]
    private var lastFetched: [GitRemote: Date] = [:]
    private var rateLimitedUntil: Date?
    private var forced: Set<GitRemote> = []
    private var lastError: String?
    private var configCache: [String: (config: [String: String], at: Date)] = [:]
    private var wakeGeneration = 0
    static let supportedHosts: Set<String> = ["github.com"]

    init(connection: Connection) {
        self.connection = connection
    }

    // MARK: - State for rendering

    var focusedContext: ExtensionContext? { contexts.first(where: \.focused) }

    /// Panes on PR branches with their Sessions and current PRs.
    var placements: [PullRequestPlacement] {
        contexts.flatMap { context in
            (context.panes ?? []).compactMap { pane -> PullRequestPlacement? in
                guard let target = targetsByPane[pane.paneID] else { return nil }
                return PullRequestPlacement(sessionKey: context.sessionKey, sessionFocused: context.focused, pane: pane,
                                            target: target, pullRequest: pullRequests[target] ?? nil)
            }
        }
    }

    // MARK: - Messages

    func handle(_ message: JSONRPCMessage) {
        switch message {
        case let .request(id, ProtocolMethod.initialize, _):
            if let result = try? ExtensionProtocolCodec.encode(InitializeResult(apiVersion: vaktaExtensionAPIVersion, name: "GitHub")) {
                connection.respond(to: id, with: result)
            }
        case let .notification(ProtocolMethod.contextsChanged, params):
            guard let params, let decoded = try? ExtensionProtocolCodec.decode(ContextsChangedParams.self, from: params) else { return }
            let previousFocus = focusedRepositories
            contexts = decoded.contexts
            resolveTargets()
            // Repositories newly in focus are refreshed right away.
            forced.formUnion(focusedRepositories.subtracting(previousFocus))
            publish()
            tick()
        case let .request(id, ProtocolMethod.shutdown, _):
            connection.respond(to: id, with: .null)
            exit(0)
        case let .request(id, method, _):
            handleRequest(id: id, method: method, message: message)
        default:
            break
        }
    }

    /// Requests other than the lifecycle ones (views, Callbacks): slices
    /// add handlers here.
    func handleRequest(id: JSONRPCID, method: String, message: JSONRPCMessage) {
        guard case let .request(_, _, params) = message else { return }
        switch method {
        case ProtocolMethod.viewRender:
            guard let params, let render = try? ExtensionProtocolCodec.decode(ViewRenderParams.self, from: params),
                  render.view == GitHubPanel.viewID else {
                return connection.fail(id, code: -32602, "no such view")
            }
            let document = GitHubPanel.view(placements, focusedRepository: focusedTarget?.repository.slug)
            if let result = try? ExtensionProtocolCodec.encode(document) { connection.respond(to: id, with: result) }
        case ProtocolMethod.callback:
            guard let params, let callback = try? ExtensionProtocolCodec.decode(CallbackParams.self, from: params) else {
                return connection.fail(id, code: -32602, "invalid callback params")
            }
            handleCallback(callback, id: id)
        default:
            connection.fail(id, code: -32601, "vakta-github doesn't handle \(method)")
        }
    }

    func handleCallback(_ callback: CallbackParams, id: JSONRPCID) {
        switch callback.callback {
        case GitHubCallbacks.openURL:
            guard case .object(let fields)? = callback.payload, case .string(let url)? = fields["url"] else {
                return connection.fail(id, code: -32602, "missing url")
            }
            respond(id, effects: [.openURL(url)])
        case GitHubActions.checkout, GitHubActions.fix, GitHubActions.copy, GitHubActions.ready, GitHubActions.draft, GitHubActions.rerun:
            guard let ref = PullRequestRef.decode(callback.payload) else { return connection.fail(id, code: -32602, "invalid pull request") }
            perform(callback.callback, ref, id: id)
        default:
            connection.fail(id, code: -32601, "unknown action \(callback.callback)")
        }
    }

    private func perform(
        _ action: String, _ ref: (url: String, number: Int, title: String, repository: String, branch: String, cwd: String?), id: JSONRPCID
    ) {
        switch action {
        case GitHubActions.checkout:
            respond(id, effects: GitHubActions.checkoutEffects(repository: ref.repository, number: ref.number, cwd: ref.cwd))
        case GitHubActions.fix:
            let state = placements.first { $0.pullRequest?.url == ref.url }?.pullRequest?.state
            let prompt = GitHubActions.fixPrompt(number: ref.number, title: ref.title, repository: ref.repository, branch: ref.branch, state: state)
            let command = GitHubActions.agentCommand(template: GitHubConfig.decode(Self.configFile()).agentCommand, prompt: prompt)
            respond(id, effects: [.openPane(cwd: ref.cwd, command: command, title: "fix #\(ref.number)"), .toast(text: "Agent started on #\(ref.number)")])
        case GitHubActions.copy:
            respond(id, effects: [.copyText(ref.url), .toast(text: "Copied link to #\(ref.number)")])
        case GitHubActions.ready, GitHubActions.draft:
            let ready = action == GitHubActions.ready
            guard let output = Tool.run(GitHubActions.readyArgv(repository: ref.repository, number: ref.number, ready: ready)), output.status == 0 else {
                return connection.fail(id, "gh couldn't change #\(ref.number).")
            }
            respond(id, effects: [.toast(text: ready ? "#\(ref.number) is ready for review" : "#\(ref.number) is a draft"), .refresh])
            refreshNow()
        case GitHubActions.rerun:
            let runs = Tool.run(GitHubActions.failedRunsArgv(repository: ref.repository, branch: ref.branch)).map { GitHubActions.runIDs($0.stdout) } ?? []
            guard !runs.isEmpty else { return connection.fail(id, "No failed workflow runs found for \(ref.branch).") }
            let rerun = runs.filter { Tool.run(GitHubActions.rerunArgv(repository: ref.repository, runID: $0))?.status == 0 }.count
            respond(id, effects: [.toast(text: "Re-running \(rerun) failed run\(rerun == 1 ? "" : "s")"), .refresh])
            refreshNow()
        default:
            break
        }
    }

    /// The focused pane's PR target.
    private var focusedTarget: PullRequestTarget? {
        GitHubStatus.focusedPane(contexts).flatMap { targetsByPane[$0.paneID] }
    }

    func respond(_ id: JSONRPCID, effects: [Effect]) {
        guard let result = try? ExtensionProtocolCodec.encode(CallbackResult(effects: effects)) else { return }
        connection.respond(to: id, with: result)
    }

    // MARK: - Targets

    private var focusedRepositories: Set<GitRemote> {
        guard let focused = focusedContext else { return [] }
        return Set((focused.panes ?? []).compactMap { targetsByPane[$0.paneID]?.repository })
    }

    private func resolveTargets() {
        var next: [String: PullRequestTarget] = [:]
        for pane in contexts.flatMap({ $0.panes ?? [] }) {
            guard let root = pane.gitRoot, let branch = pane.branch,
                  let target = RepoConfig.target(config: config(root), branch: branch, supportedHosts: Self.supportedHosts)
            else { continue }
            next[pane.paneID] = target
        }
        targetsByPane = next
    }

    private func config(_ root: String) -> [String: String] {
        if let cached = configCache[root], Date().timeIntervalSince(cached.at) < 60 { return cached.config }
        let output = Tool.run(["git", "--no-optional-locks", "-C", root, "config", "-z", "--get-regexp", RepoConfig.pattern], timeout: 5)
        let config = output.map { RepoConfig.parse($0.stdout) } ?? [:]
        configCache[root] = (config, Date())
        return config
    }

    // MARK: - Refresh

    /// Fetches due repositories, publishes, and schedules the next wake.
    func tick() {
        let targets = Set(targetsByPane.values)
        let repositories = Set(targets.map(\.repository))
        let pending = Set(targets.filter { (pullRequests[$0] ?? nil)?.pending ?? 0 > 0 }.map(\.repository))
        let intervals = RefreshIntervals.decode(Self.configFile())
        let now = Date()
        let due = RefreshPlanner.due(
            repositories: repositories, focused: focusedRepositories, pending: pending, forced: forced,
            lastFetched: lastFetched, now: now, intervals: intervals, rateLimitedUntil: rateLimitedUntil
        )
        forced.subtract(due)
        if !due.isEmpty { fetch(targets.filter { due.contains($0.repository) }) }
        schedule(RefreshPlanner.nextDue(
            repositories: repositories, focused: focusedRepositories, pending: pending,
            lastFetched: lastFetched, now: Date(), intervals: intervals, rateLimitedUntil: rateLimitedUntil
        ))
    }

    /// Refreshes `repositories` now (after an action, or a `refresh`).
    func refreshNow(_ repositories: Set<GitRemote>? = nil) {
        forced.formUnion(repositories ?? Set(targetsByPane.values.map(\.repository)))
        tick()
    }

    private func fetch(_ targets: Set<PullRequestTarget>) {
        for (host, hostTargets) in Dictionary(grouping: targets, by: \.repository.host) {
            let query = PullRequestQuery(targets: hostTargets.sorted { "\($0.repository.slug) \($0.branch)" < "\($1.repository.slug) \($1.branch)" })
            let fetchedAt = Date()
            switch api.fetch(query, host: host) {
            case .success(let result):
                for (target, pullRequest) in result.pullRequests { pullRequests[target] = .some(pullRequest) }
                for repository in Set(hostTargets.map(\.repository)) { lastFetched[repository] = fetchedAt }
                rateLimitedUntil = RefreshPlanner.rateLimitedUntil(remaining: result.rateRemaining, resetsAt: result.rateResetsAt)
                lastError = nil
            case .failure(.rateLimited(let resetsAt)):
                rateLimitedUntil = resetsAt ?? Date().addingTimeInterval(300)
                lastError = "GitHub rate limit reached."
            case .failure(let error):
                // Try again after the normal interval rather than hammering.
                for repository in Set(hostTargets.map(\.repository)) { lastFetched[repository] = fetchedAt }
                lastError = "\(error)"
                connection.log(.warning, "GitHub query failed: \(error)")
            }
        }
        publish()
    }

    private func schedule(_ date: Date?) {
        wakeGeneration += 1
        let generation = wakeGeneration
        let delay = min(60, max(1, (date ?? Date().addingTimeInterval(60)).timeIntervalSinceNow))
        connection.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wakeGeneration == generation else { return }
            self.tick()
        }
    }

    // MARK: - Publishing (filled in by the status, panel and badge slices)

    private var lastStates: [String: PullRequestState] = [:]
    private var lastStatus: StatusSetParams??

    func publish() {
        let current = placements
        let summary = current.map { "\($0.target.repository.slug)@\($0.target.branch)=\($0.pullRequest.map { "#\($0.number) \($0.state)" } ?? "none")" }
        connection.log(.debug, "prs: \(Set(summary).sorted().joined(separator: ", "))")

        let prs = GitHubStatus.distinct(current)
        let changed = GitHubNotices.transitions(previous: lastStates, current: prs)
        for pr in prs { lastStates[pr.url] = pr.state }
        for pr in changed {
            let session = current.first { $0.pullRequest?.url == pr.url }?.sessionKey
            send(ProtocolMethod.notify, GitHubNotices.notice(for: pr, sessionKey: session))
        }
        sendStatus(GitHubStatus.statusItem(contexts: contexts, placements: current, attention: Set(changed.map(\.url))))

        let focusedPlacement = GitHubStatus.focusedPane(contexts).flatMap { pane in current.first { $0.pane.paneID == pane.paneID } }
        let ref = focusedPlacement.flatMap { placement in
            placement.pullRequest.map { PullRequestRef($0, target: placement.target, cwd: placement.pane.gitRoot) }
        }
        let commands = GitHubActions.commands(ref)
        if commands != lastCommands {
            lastCommands = commands
            send(ProtocolMethod.commandsSet, CommandsSetParams(commands: commands))
        }

        let nextBadges = GitHubBadges.badges(current)
        for message in GitHubBadges.changes(from: badges, to: nextBadges) { connection.send(message) }
        badges = nextBadges

        // Keep the panel live: re-render when what it shows changed.
        let panel = GitHubPanel.view(current, focusedRepository: focusedTarget?.repository.slug)
        if panel != lastPanel {
            lastPanel = panel
            send(ProtocolMethod.viewInvalidate, ViewInvalidateParams(view: GitHubPanel.viewID))
        }
    }

    private var lastCommands: [ExtensionCommand]?
    private var badges: [SessionKey: BadgeSetParams] = [:]
    private var lastPanel: ViewDocument?

    private func sendStatus(_ status: StatusSetParams?) {
        guard lastStatus != .some(status) else { return }
        lastStatus = .some(status)
        if let status {
            send(ProtocolMethod.statusSet, status)
        } else {
            connection.send(.notification(method: ProtocolMethod.statusClear, params: nil))
        }
    }

    func send<Params: Encodable>(_ method: String, _ params: Params) {
        guard let encoded = try? ExtensionProtocolCodec.encode(params) else { return }
        connection.send(.notification(method: method, params: encoded))
    }

    static func configFile() -> Data? {
        ProcessInfo.processInfo.environment["VAKTA_EXTENSION_CONFIG_DIR"].flatMap {
            try? Data(contentsOf: URL(fileURLWithPath: $0).appendingPathComponent("config.json"))
        }
    }
}
