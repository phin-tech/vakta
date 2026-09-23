//
//  PullRequestStatusPlanning.swift
//  Vakta
//
//  Pure decisions behind `PullRequestStatusStore`: which repositories are
//  due for a `gh` refresh, how an outcome updates the cache (a failure keeps
//  the last good index), and how cached indexes project onto panes, a
//  session's focused pane, and per-workspace summaries.

import Foundation

struct PullRequestRefreshPolicy: Equatable {
    /// Refresh age for the repository behind the focused pane.
    var focusedMaxAge: TimeInterval
    /// Refresh age for every other repository, and the back-off after gh is
    /// found missing or logged out.
    var backgroundMaxAge: TimeInterval

    static let standard = PullRequestRefreshPolicy(focusedMaxAge: 60, backgroundMaxAge: 300)
}

struct PullRequestCacheEntry: Equatable {
    /// The last successfully fetched index, kept across later failures.
    var index: PullRequestIndex?
    /// When the last attempt (successful or not) completed.
    var fetchedAt: Date
    /// The last attempt's outcome when it wasn't a success.
    var lastFailure: PullRequestListOutcome?
}

enum PullRequestRefreshPlanner {
    /// Repositories (in input order) whose cache entry is missing or older
    /// than their allowed age. `forceFocused` refreshes the focused
    /// repository regardless of age -- e.g. on window focus, so a PR pushed
    /// moments ago appears. gh missing or logged out won't fix itself within
    /// a minute, so those back off to the background age unless forced.
    static func repositoriesToFetch(
        repositories: [GitRemote],
        cache: [GitRemote: PullRequestCacheEntry],
        focused: GitRemote?,
        now: Date,
        forceFocused: Bool,
        policy: PullRequestRefreshPolicy
    ) -> [GitRemote] {
        var seen = Set<GitRemote>()
        return repositories.filter { repository in
            guard seen.insert(repository).inserted else { return false }
            guard let entry = cache[repository] else { return true }
            let isFocused = repository == focused
            if isFocused && forceFocused { return true }
            let maxAge: TimeInterval
            switch entry.lastFailure {
            case .ghUnavailable?, .notAuthenticated?:
                maxAge = policy.backgroundMaxAge
            default:
                maxAge = isFocused ? policy.focusedMaxAge : policy.backgroundMaxAge
            }
            return now.timeIntervalSince(entry.fetchedAt) >= maxAge
        }
    }

    static func applying(_ outcome: PullRequestListOutcome, to entry: PullRequestCacheEntry?, at date: Date) -> PullRequestCacheEntry {
        if case .pullRequests(let index) = outcome {
            return PullRequestCacheEntry(index: index, fetchedAt: date, lastFailure: nil)
        }
        return PullRequestCacheEntry(index: entry?.index, fetchedAt: date, lastFailure: outcome)
    }

    static func pruned(
        _ cache: [GitRemote: PullRequestCacheEntry],
        liveRepositories: Set<GitRemote>
    ) -> [GitRemote: PullRequestCacheEntry] {
        cache.filter { liveRepositories.contains($0.key) }
    }
}

/// What the status bar shows for a session: the focused pane's branch, and
/// its PR when one is open.
struct FocusedPullRequestState: Equatable {
    let target: PullRequestTarget
    let pullRequest: PullRequestStatus?
}

struct PullRequestSummary: Equatable {
    var pullRequestCount: Int
    var failingChecks: Int
    var changesRequested: Int

    var needsAttention: Bool { failingChecks > 0 || changesRequested > 0 }
}

enum PullRequestStatusProjection {
    static func statuses(
        targetsByPaneID: [String: PullRequestTarget],
        cache: [GitRemote: PullRequestCacheEntry]
    ) -> [String: PullRequestStatus] {
        targetsByPaneID.compactMapValues { target in
            cache[target.repository]?.index?.pullRequest(branch: target.branch, headOwner: target.headOwner)
        }
    }

    /// The focused pane's state; nil when no pane is focused or the focused
    /// pane isn't in a supported checkout.
    static func focusedState(
        panes: [Pane],
        targetsByPaneID: [String: PullRequestTarget],
        statuses: [String: PullRequestStatus]
    ) -> FocusedPullRequestState? {
        guard let pane = panes.first(where: \.focused), let target = targetsByPaneID[pane.id] else { return nil }
        return FocusedPullRequestState(target: target, pullRequest: statuses[pane.id])
    }

    /// Per-workspace counts over distinct PRs (several panes on one branch
    /// count once). Workspaces with no PR are omitted, as are panes whose
    /// backend reported no workspace.
    static func workspaceSummaries(panes: [Pane], statuses: [String: PullRequestStatus]) -> [String: PullRequestSummary] {
        var pullRequestsByWorkspace: [String: [String: PullRequestStatus]] = [:]
        for pane in panes {
            guard let workspaceID = pane.workspaceID, let status = statuses[pane.id] else { continue }
            pullRequestsByWorkspace[workspaceID, default: [:]][status.url] = status
        }
        return pullRequestsByWorkspace.mapValues { byURL in
            let pullRequests = Array(byURL.values)
            return PullRequestSummary(
                pullRequestCount: pullRequests.count,
                failingChecks: pullRequests.filter { $0.checks.state == .failing }.count,
                changesRequested: pullRequests.filter { $0.review == .changesRequested }.count
            )
        }
    }
}
