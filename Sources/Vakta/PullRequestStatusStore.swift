//
//  PullRequestStatusStore.swift
//  Vakta
//
//  Owns the PR status refresh cycle for every pane in every multiplexer
//  session: list panes → resolve new/stale working directories to checkouts
//  → plan PR targets → fetch the repositories that are due (one `gh` call
//  each) → publish the focused pane's state and per-workspace summaries.
//  The whole cycle runs off the main actor; at most one runs at a time, and
//  requests arriving meanwhile collapse into one follow-up (the latest
//  sessions, with `forceFocused` sticky). Decisions live in
//  `PullRequestStatusPlanning.swift` / `RepoCheckout.swift`.

import Foundation

struct PullRequestSessionSnapshot {
    let id: Session.ID
    let sessionName: String
    let target: MultiplexerTarget
}

@MainActor
final class PullRequestStatusStore: ObservableObject {
    /// Per session: its focused pane's branch and PR. Absent when no pane
    /// is focused in a supported checkout.
    @Published private(set) var focused: [Session.ID: FocusedPullRequestState] = [:]
    /// Per session, per workspace id: counts over distinct PRs.
    @Published private(set) var workspaceSummaries: [Session.ID: [String: PullRequestSummary]] = [:]
    /// Per session, per workspace id: its distinct PRs, by number.
    @Published private(set) var workspacePullRequests: [Session.ID: [String: [PullRequestStatus]]] = [:]
    /// Per session: the focused pane's workspace id.
    @Published private(set) var focusedWorkspace: [Session.ID: String] = [:]

    private struct Request {
        var sessions: [PullRequestSessionSnapshot]
        var focusedSessionID: Session.ID?
        var forceFocused: Bool
        var environment: [String: String]
    }

    private struct CycleResult {
        let startedAt: Date
        /// Sessions whose pane listing succeeded; a failed listing keeps the
        /// session's previously published state.
        let panesBySession: [Session.ID: [Pane]]
        let targetsBySession: [Session.ID: [String: PullRequestTarget]]
        let directories: Set<String>
        let resolvedCheckouts: [String: RepoCheckoutCacheEntry]
        let liveRepositories: Set<GitRemote>
        let fetched: [GitRemote: PullRequestListOutcome]
    }

    /// Each helper receives the request's helper environment (PATH/HOME).
    private let listPanes: (PullRequestSessionSnapshot, [String: String]) -> [Pane]?
    private let resolveCheckout: (String, [String: String]) -> RepoCheckout?
    private let listPullRequests: (GitRemote, [String: String]) -> PullRequestListOutcome
    private let now: () -> Date
    private let runInBackground: (@escaping @Sendable () -> Void) -> Void
    private let policy: PullRequestRefreshPolicy
    private let checkoutMaxAge: TimeInterval
    private let supportedHosts: Set<String>

    private var checkoutCache: [String: RepoCheckoutCacheEntry] = [:]
    private var pullRequestCache: [GitRemote: PullRequestCacheEntry] = [:]
    /// Sessions named by the latest request; results for any other session
    /// are dropped when a cycle lands.
    private var liveSessionIDs: Set<Session.ID> = []
    private var isRunning = false
    private var owed: Request?

    init(
        listPanes: @escaping (PullRequestSessionSnapshot, [String: String]) -> [Pane]?,
        resolveCheckout: @escaping (String, [String: String]) -> RepoCheckout?,
        listPullRequests: @escaping (GitRemote, [String: String]) -> PullRequestListOutcome,
        now: @escaping () -> Date = Date.init,
        runInBackground: @escaping (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.global(qos: .utility).async(execute: $0)
        },
        policy: PullRequestRefreshPolicy = .standard,
        checkoutMaxAge: TimeInterval = 60,
        supportedHosts: Set<String> = ["github.com"]
    ) {
        self.listPanes = listPanes
        self.resolveCheckout = resolveCheckout
        self.listPullRequests = listPullRequests
        self.now = now
        self.runInBackground = runInBackground
        self.policy = policy
        self.checkoutMaxAge = checkoutMaxAge
        self.supportedHosts = supportedHosts
    }

    /// Runs a cycle for `sessions` (or queues one behind the running cycle).
    /// Sessions missing from `sessions` lose their published state now.
    /// `environment` is what the multiplexer, git, and gh helpers run with.
    func refresh(
        sessions: [PullRequestSessionSnapshot],
        focusedSessionID: Session.ID?,
        forceFocused: Bool,
        environment: [String: String] = [:]
    ) {
        liveSessionIDs = Set(sessions.map(\.id))
        dropPublishedState(forSessionsNotIn: liveSessionIDs)
        let request = Request(sessions: sessions, focusedSessionID: focusedSessionID, forceFocused: forceFocused, environment: environment)
        if isRunning {
            owed = Request(
                sessions: sessions,
                focusedSessionID: focusedSessionID,
                forceFocused: forceFocused || (owed?.forceFocused ?? false),
                environment: environment
            )
        } else {
            start(request)
        }
    }

    private func dropPublishedState(forSessionsNotIn live: Set<Session.ID>) {
        if focused.keys.contains(where: { !live.contains($0) }) {
            focused = focused.filter { live.contains($0.key) }
        }
        if workspaceSummaries.keys.contains(where: { !live.contains($0) }) {
            workspaceSummaries = workspaceSummaries.filter { live.contains($0.key) }
        }
        if workspacePullRequests.keys.contains(where: { !live.contains($0) }) {
            workspacePullRequests = workspacePullRequests.filter { live.contains($0.key) }
        }
        if focusedWorkspace.keys.contains(where: { !live.contains($0) }) {
            focusedWorkspace = focusedWorkspace.filter { live.contains($0.key) }
        }
    }

    private func start(_ request: Request) {
        isRunning = true
        let startedAt = now()
        let checkoutCache = self.checkoutCache
        let pullRequestCache = self.pullRequestCache
        let listPanes = self.listPanes
        let resolveCheckout = self.resolveCheckout
        let listPullRequests = self.listPullRequests
        let policy = self.policy
        let checkoutMaxAge = self.checkoutMaxAge
        let supportedHosts = self.supportedHosts

        runInBackground { [weak self] in
            var panesBySession: [Session.ID: [Pane]] = [:]
            var directories: [String] = []
            for session in request.sessions {
                guard let panes = listPanes(session, request.environment) else { continue }
                panesBySession[session.id] = panes
                directories += panes.compactMap(\.workingDirectory)
            }

            let cachePlan = RepoCheckoutCachePlanner.plan(
                directories: directories,
                cache: checkoutCache,
                now: startedAt,
                maxAge: checkoutMaxAge
            )
            var resolved: [String: RepoCheckoutCacheEntry] = [:]
            for directory in cachePlan.toResolve {
                resolved[directory] = RepoCheckoutCacheEntry(checkout: resolveCheckout(directory, request.environment), resolvedAt: startedAt)
            }
            let checkouts = checkoutCache.merging(resolved) { $1 }.mapValues(\.checkout)

            var targetsBySession: [Session.ID: [String: PullRequestTarget]] = [:]
            var repositories: [GitRemote] = []
            var focusedRepository: GitRemote?
            for session in request.sessions {
                guard let panes = panesBySession[session.id] else { continue }
                let plan = PullRequestTargetPlanner.plan(panes: panes, checkouts: checkouts, supportedHosts: supportedHosts)
                targetsBySession[session.id] = plan.targetsByPaneID
                repositories += plan.repositories
                if session.id == request.focusedSessionID,
                   let pane = panes.first(where: \.focused) {
                    focusedRepository = plan.targetsByPaneID[pane.id]?.repository
                }
            }

            let due = PullRequestRefreshPlanner.repositoriesToFetch(
                repositories: repositories,
                cache: pullRequestCache,
                focused: focusedRepository,
                now: startedAt,
                forceFocused: request.forceFocused,
                policy: policy
            )
            var fetched: [GitRemote: PullRequestListOutcome] = [:]
            for repository in due {
                fetched[repository] = listPullRequests(repository, request.environment)
            }

            let result = CycleResult(
                startedAt: startedAt,
                panesBySession: panesBySession,
                targetsBySession: targetsBySession,
                directories: Set(directories),
                resolvedCheckouts: resolved,
                liveRepositories: Set(repositories),
                fetched: fetched
            )
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func finish(_ result: CycleResult) {
        isRunning = false

        checkoutCache = checkoutCache
            .filter { result.directories.contains($0.key) }
            .merging(result.resolvedCheckouts) { $1 }
        for (repository, outcome) in result.fetched {
            pullRequestCache[repository] = PullRequestRefreshPlanner.applying(
                outcome,
                to: pullRequestCache[repository],
                at: result.startedAt
            )
        }
        pullRequestCache = PullRequestRefreshPlanner.pruned(pullRequestCache, liveRepositories: result.liveRepositories)

        var nextFocused = focused.filter { liveSessionIDs.contains($0.key) }
        var nextSummaries = workspaceSummaries.filter { liveSessionIDs.contains($0.key) }
        var nextLists = workspacePullRequests.filter { liveSessionIDs.contains($0.key) }
        var nextFocusedWorkspace = focusedWorkspace.filter { liveSessionIDs.contains($0.key) }
        for (sessionID, panes) in result.panesBySession where liveSessionIDs.contains(sessionID) {
            let targets = result.targetsBySession[sessionID] ?? [:]
            let statuses = PullRequestStatusProjection.statuses(targetsByPaneID: targets, cache: pullRequestCache)
            nextFocused[sessionID] = PullRequestStatusProjection.focusedState(panes: panes, targetsByPaneID: targets, statuses: statuses)
            nextSummaries[sessionID] = PullRequestStatusProjection.workspaceSummaries(panes: panes, statuses: statuses)
            nextLists[sessionID] = PullRequestStatusProjection.workspacePullRequests(panes: panes, statuses: statuses)
            nextFocusedWorkspace[sessionID] = PullRequestStatusProjection.focusedWorkspaceID(panes: panes)
        }
        if nextFocused != focused { focused = nextFocused }
        if nextSummaries != workspaceSummaries { workspaceSummaries = nextSummaries }
        if nextLists != workspacePullRequests { workspacePullRequests = nextLists }
        if nextFocusedWorkspace != focusedWorkspace { focusedWorkspace = nextFocusedWorkspace }

        if let next = owed {
            owed = nil
            start(next)
        }
    }
}
