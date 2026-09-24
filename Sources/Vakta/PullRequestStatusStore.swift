//
//  PullRequestStatusStore.swift
//  Vakta
//
//  Owns PR status for every pane in every multiplexer session, stale-while-
//  revalidate: a pane cycle lists panes, resolves new/stale working
//  directories to checkouts, plans PR targets, and publishes at once from
//  cached PR indexes; the repositories that are due are then fetched (one
//  `gh` call each) by a separate job whose results republish as they land.
//  A pane switch is therefore never held behind the network. At most one
//  pane cycle runs at a time -- requests arriving meanwhile collapse into one
//  follow-up (the latest sessions, `forceFocused` sticky) -- and a
//  repository is never fetched twice at once. Decisions live in
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
        /// List only this session's panes (a pane switch in it); nil lists
        /// every session.
        var onlySessionID: Session.ID?
    }

    private struct CycleResult {
        let request: Request
        let startedAt: Date
        /// Sessions whose pane listing succeeded; a failed listing keeps the
        /// session's previously published state.
        let panesBySession: [Session.ID: [Pane]]
        let targetsBySession: [Session.ID: [String: PullRequestTarget]]
        let directories: Set<String>
        let resolvedCheckouts: [String: RepoCheckoutCacheEntry]

        /// A partial cycle saw only some sessions' panes, so it must not
        /// prune caches other sessions still use.
        var isPartial: Bool { request.onlySessionID != nil }
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
    /// Each session's latest listed panes and their targets; published state
    /// is recomputed from these plus the caches.
    private var panesBySession: [Session.ID: [Pane]] = [:]
    private var targetsBySession: [Session.ID: [String: PullRequestTarget]] = [:]
    private var inFlight: Set<GitRemote> = []
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
    /// `onlySessionID` lists just that session's panes (the rest keep their
    /// published state and caches) -- cheap enough to run on a pane switch.
    func refresh(
        sessions: [PullRequestSessionSnapshot],
        focusedSessionID: Session.ID?,
        forceFocused: Bool,
        environment: [String: String] = [:],
        onlySessionID: Session.ID? = nil
    ) {
        liveSessionIDs = Set(sessions.map(\.id))
        dropPublishedState(forSessionsNotIn: liveSessionIDs)
        let request = Request(
            sessions: sessions,
            focusedSessionID: focusedSessionID,
            forceFocused: forceFocused,
            environment: environment,
            onlySessionID: onlySessionID
        )
        if isRunning {
            // A queued full cycle covers any partial one; two partials for
            // different sessions widen to a full cycle.
            let only: Session.ID?
            if let owed {
                only = owed.onlySessionID == onlySessionID ? onlySessionID : nil
            } else {
                only = onlySessionID
            }
            owed = Request(
                sessions: sessions,
                focusedSessionID: focusedSessionID,
                forceFocused: forceFocused || (owed?.forceFocused ?? false),
                environment: environment,
                onlySessionID: only
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
        let listPanes = self.listPanes
        let resolveCheckout = self.resolveCheckout
        let checkoutMaxAge = self.checkoutMaxAge
        let supportedHosts = self.supportedHosts

        runInBackground { [weak self] in
            var panesBySession: [Session.ID: [Pane]] = [:]
            var directories: [String] = []
            let listed = request.onlySessionID.map { only in request.sessions.filter { $0.id == only } } ?? request.sessions
            for session in listed {
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
            for (sessionID, panes) in panesBySession {
                targetsBySession[sessionID] = PullRequestTargetPlanner.plan(
                    panes: panes,
                    checkouts: checkouts,
                    supportedHosts: supportedHosts
                ).targetsByPaneID
            }

            let result = CycleResult(
                request: request,
                startedAt: startedAt,
                panesBySession: panesBySession,
                targetsBySession: targetsBySession,
                directories: Set(directories),
                resolvedCheckouts: resolved
            )
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func finish(_ result: CycleResult) {
        isRunning = false

        checkoutCache = checkoutCache
            .filter { result.isPartial || result.directories.contains($0.key) }
            .merging(result.resolvedCheckouts) { $1 }
        panesBySession = panesBySession.filter { liveSessionIDs.contains($0.key) }
            .merging(result.panesBySession.filter { liveSessionIDs.contains($0.key) }) { $1 }
        targetsBySession = targetsBySession.filter { liveSessionIDs.contains($0.key) }
            .merging(result.targetsBySession.filter { liveSessionIDs.contains($0.key) }) { $1 }
        if !result.isPartial {
            pullRequestCache = PullRequestRefreshPlanner.pruned(pullRequestCache, liveRepositories: liveRepositories)
        }

        publish()
        fetchDueRepositories(for: result.request, at: result.startedAt)

        if let next = owed {
            owed = nil
            start(next)
        }
    }

    /// Repositories any live session's panes point at, in session order.
    private var liveRepositoryList: [GitRemote] {
        var repositories: [GitRemote] = []
        for targets in targetsBySession.values {
            for target in targets.values.sorted(by: { $0.repository.ghRepository < $1.repository.ghRepository })
            where !repositories.contains(target.repository) {
                repositories.append(target.repository)
            }
        }
        return repositories
    }

    private var liveRepositories: Set<GitRemote> { Set(liveRepositoryList) }

    /// Starts one background job fetching every due repository that isn't
    /// already being fetched; each result republishes as it lands.
    private func fetchDueRepositories(for request: Request, at date: Date) {
        let focusedRepository = request.focusedSessionID.flatMap { sessionID -> GitRemote? in
            guard let pane = panesBySession[sessionID]?.first(where: \.focused) else { return nil }
            return targetsBySession[sessionID]?[pane.id]?.repository
        }
        let due = PullRequestRefreshPlanner.repositoriesToFetch(
            repositories: liveRepositoryList,
            cache: pullRequestCache,
            focused: focusedRepository,
            now: date,
            forceFocused: request.forceFocused,
            policy: policy,
            inFlight: inFlight
        )
        guard !due.isEmpty else { return }
        // The focused repository first, so the bar's own PR lands soonest.
        let ordered = due.sorted { first, _ in first == focusedRepository }
        inFlight.formUnion(ordered)
        let listPullRequests = self.listPullRequests
        let environment = request.environment
        runInBackground { [weak self] in
            for repository in ordered {
                let outcome = listPullRequests(repository, environment)
                DispatchQueue.main.async { self?.applyFetch(outcome, for: repository, at: date) }
            }
        }
    }

    /// Drops a result for a repository no live pane points at any more (its
    /// cache entry was pruned while the fetch ran).
    private func applyFetch(_ outcome: PullRequestListOutcome, for repository: GitRemote, at date: Date) {
        inFlight.remove(repository)
        guard liveRepositories.contains(repository) else { return }
        pullRequestCache[repository] = PullRequestRefreshPlanner.applying(outcome, to: pullRequestCache[repository], at: date)
        publish()
    }

    /// Recomputes every live session's published state from its latest
    /// panes, targets, and the PR cache.
    private func publish() {
        var nextFocused = focused.filter { liveSessionIDs.contains($0.key) }
        var nextSummaries = workspaceSummaries.filter { liveSessionIDs.contains($0.key) }
        var nextLists = workspacePullRequests.filter { liveSessionIDs.contains($0.key) }
        var nextFocusedWorkspace = focusedWorkspace.filter { liveSessionIDs.contains($0.key) }
        for (sessionID, panes) in panesBySession where liveSessionIDs.contains(sessionID) {
            let targets = targetsBySession[sessionID] ?? [:]
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
    }
}
