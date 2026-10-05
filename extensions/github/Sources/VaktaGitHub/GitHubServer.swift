//
//  GitHubServer.swift
//  vakta-github
//
//  The GitHub Extension's handlers on VaktaExtensionServer. Every method
//  runs on `server.queue` (serial), including the refresh timer, so state is
//  never touched concurrently (hence `@unchecked Sendable`).

import Foundation
import GitHubCore
import VaktaExtensionKit
import VaktaExtensionServer

final class GitHubServer: @unchecked Sendable {
    private let server: ExtensionServer
    private let api = GitHubAPI()

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

    init(server: ExtensionServer) {
        self.server = server
        server.onContexts = { [unowned self] previous, current in
            let previousFocus = focusedRepositories(in: previous)
            resolveTargets(current)
            // Repositories newly in focus are refreshed right away.
            forced.formUnion(focusedRepositories(in: current).subtracting(previousFocus))
            publish()
            tick()
        }
        server.onRender(GitHubPanel.viewID) { [unowned self] in GitHubPanel.view(placements, focusedRepository: focusedTarget?.repository.slug) }
        registerCallbacks()
    }

    // MARK: - State for rendering

    private var contexts: [ExtensionContext] { server.contexts }
    private var focusedContext: ExtensionContext? { server.focusedContext }

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

    // MARK: - Callbacks

    private func registerCallbacks() {
        server.onCallback(GitHubCallbacks.openURL) { callback in
            guard case .object(let fields)? = callback.payload, case .string(let url)? = fields["url"] else {
                throw ExtensionError.invalidParams("missing url")
            }
            return [.openURL(url)]
        }
        for action in [GitHubActions.checkout, GitHubActions.fix, GitHubActions.copy, GitHubActions.ready, GitHubActions.draft, GitHubActions.rerun] {
            server.onCallback(action) { [unowned self] callback in
                guard let ref = PullRequestRef.decode(callback.payload) else { throw ExtensionError.invalidParams("invalid pull request") }
                return try perform(action, ref)
            }
        }
    }

    private func perform(_ action: String, _ ref: (url: String, number: Int, title: String, repository: String, branch: String, cwd: String?)) throws -> [Effect] {
        switch action {
        case GitHubActions.checkout:
            return GitHubActions.checkoutEffects(repository: ref.repository, number: ref.number, cwd: ref.cwd)
        case GitHubActions.fix:
            let state = placements.first { $0.pullRequest?.url == ref.url }?.pullRequest?.state
            let prompt = GitHubActions.fixPrompt(number: ref.number, title: ref.title, repository: ref.repository, branch: ref.branch, state: state)
            let command = GitHubActions.agentCommand(template: GitHubConfig.decode(Self.configFile()).agentCommand, prompt: prompt)
            return [.openPane(cwd: ref.cwd, command: command, title: "fix #\(ref.number)"), .toast(text: "Agent started on #\(ref.number)")]
        case GitHubActions.copy:
            return [.copyText(ref.url), .toast(text: "Copied link to #\(ref.number)")]
        case GitHubActions.ready, GitHubActions.draft:
            let ready = action == GitHubActions.ready
            guard let output = Tool.run(GitHubActions.readyArgv(repository: ref.repository, number: ref.number, ready: ready)), output.status == 0 else {
                throw ExtensionError("gh couldn't change #\(ref.number).")
            }
            refreshNow()
            return [.toast(text: ready ? "#\(ref.number) is ready for review" : "#\(ref.number) is a draft"), .refresh]
        case GitHubActions.rerun:
            let runs = Tool.run(GitHubActions.failedRunsArgv(repository: ref.repository, branch: ref.branch)).map { GitHubActions.runIDs($0.stdout) } ?? []
            guard !runs.isEmpty else { throw ExtensionError("No failed workflow runs found for \(ref.branch).") }
            let rerun = runs.filter { Tool.run(GitHubActions.rerunArgv(repository: ref.repository, runID: $0))?.status == 0 }.count
            refreshNow()
            return [.toast(text: "Re-running \(rerun) failed run\(rerun == 1 ? "" : "s")"), .refresh]
        default:
            return []
        }
    }

    /// The focused pane's PR target.
    private var focusedTarget: PullRequestTarget? {
        GitHubStatus.focusedPane(contexts).flatMap { targetsByPane[$0.paneID] }
    }

    // MARK: - Targets

    private func focusedRepositories(in contexts: [ExtensionContext]) -> Set<GitRemote> {
        guard let focused = contexts.first(where: \.focused) else { return [] }
        return Set((focused.panes ?? []).compactMap { targetsByPane[$0.paneID]?.repository })
    }

    private func resolveTargets(_ contexts: [ExtensionContext]) {
        var resolved: [String: PullRequestTarget??] = [:]
        for pane in contexts.flatMap({ $0.panes ?? [] }) {
            guard let root = pane.gitRoot, let branch = pane.branch else {
                resolved[pane.paneID] = .none
                continue
            }
            resolved[pane.paneID] = .some(RepoConfig.target(config: config(root), branch: branch, supportedHosts: Self.supportedHosts))
        }
        targetsByPane = TargetResolution.next(resolved: resolved, previous: targetsByPane)
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
        let focused = focusedRepositories(in: contexts)
        let due = RefreshPlanner.due(
            repositories: repositories, focused: focused, pending: pending, forced: forced,
            lastFetched: lastFetched, now: now, intervals: intervals, rateLimitedUntil: rateLimitedUntil
        )
        forced.subtract(due)
        if !due.isEmpty { fetch(targets.filter { due.contains($0.repository) }) }
        schedule(RefreshPlanner.nextDue(
            repositories: repositories, focused: focused, pending: pending,
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
                server.log(.warning, "GitHub query failed: \(error)")
            }
        }
        publish()
    }

    private func schedule(_ date: Date?) {
        wakeGeneration += 1
        let generation = wakeGeneration
        let delay = min(60, max(1, (date ?? Date().addingTimeInterval(60)).timeIntervalSinceNow))
        server.after(delay) { [weak self] in
            guard let self, self.wakeGeneration == generation else { return }
            self.tick()
        }
    }

    // MARK: - Publishing (only changes are sent)

    private var lastStates: [String: PullRequestState] = [:]
    private var lastPanel: ViewDocument?

    func publish() {
        let current = placements
        let summary = current.map { "\($0.target.repository.slug)@\($0.target.branch)=\($0.pullRequest.map { "#\($0.number) \($0.state)" } ?? "none")" }
        server.log(.debug, "prs: \(Set(summary).sorted().joined(separator: ", "))")

        let prs = GitHubStatus.distinct(current)
        let changed = GitHubNotices.transitions(previous: lastStates, current: prs)
        for pr in prs { lastStates[pr.url] = pr.state }
        for pr in changed {
            let session = current.first { $0.pullRequest?.url == pr.url }?.sessionKey
            let notice = GitHubNotices.notice(for: pr, sessionKey: session)
            server.notify(title: notice.title, body: notice.body, sessionKey: notice.sessionKey)
        }
        server.setStatus(GitHubStatus.statusItem(contexts: contexts, placements: current, attention: Set(changed.map(\.url))))

        let focusedPlacement = GitHubStatus.focusedPane(contexts).flatMap { pane in current.first { $0.pane.paneID == pane.paneID } }
        let ref = focusedPlacement.flatMap { placement in
            placement.pullRequest.map { PullRequestRef($0, target: placement.target, cwd: placement.pane.gitRoot) }
        }
        server.setCommands(GitHubActions.commands(ref))
        server.setBadges(GitHubBadges.badges(current))

        // Keep the panel live: re-render when what it shows changed.
        let panel = GitHubPanel.view(current, focusedRepository: focusedTarget?.repository.slug)
        if panel != lastPanel {
            lastPanel = panel
            server.invalidate(view: GitHubPanel.viewID)
        }
    }

    static func configFile() -> Data? {
        ProcessInfo.processInfo.environment["VAKTA_EXTENSION_CONFIG_DIR"].flatMap {
            try? Data(contentsOf: URL(fileURLWithPath: $0).appendingPathComponent("config.json"))
        }
    }
}
