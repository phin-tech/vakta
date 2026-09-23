//
//  RepoCheckout.swift
//  Vakta
//
//  Pure decisions that turn pane working directories into PR lookup keys.
//  A directory resolves (via `RepoCheckoutQuery`) to its checkout's root,
//  branch, and remote configuration; that becomes a `PullRequestTarget`
//  naming the repository the PR lives in, the head branch, and the head
//  repository's owner. Targets deliberately omit the checkout root, so panes
//  in different worktrees of one repository share a single `gh` call.

import Foundation

/// A GitHub-style remote: host plus exactly `owner/name`.
struct GitRemote: Hashable {
    let host: String
    let owner: String
    let name: String

    /// gh's `--repo` spelling: `owner/name` on github.com, `host/owner/name`
    /// on an enterprise host.
    var ghRepository: String {
        host == "github.com" ? "\(owner)/\(name)" : "\(host)/\(owner)/\(name)"
    }

    init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// Parses URL forms (`ssh://`, `https://`, `git://`, optional user and
    /// port) and scp-style `[user@]host:owner/name`, with or without `.git`.
    /// Local paths, `file://`, and paths that aren't exactly `owner/name` are
    /// nil. An ssh host alias (`github-work:o/r`) parses with the alias as
    /// the host, which callers then reject as unsupported.
    init?(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  ["ssh", "https", "http", "git"].contains(scheme),
                  let componentHost = components.host, !componentHost.isEmpty
            else { return nil }
            host = componentHost
            path = components.path
        } else {
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let authority = trimmed[..<colon]
            guard !authority.isEmpty, !authority.contains("/") else { return nil }
            host = String(authority.split(separator: "@").last ?? authority)
            path = String(trimmed[trimmed.index(after: colon)...])
        }

        var repositoryPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if repositoryPath.hasSuffix(".git") { repositoryPath.removeLast(4) }
        let segments = repositoryPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !host.isEmpty, segments.count == 2, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.init(host: host.lowercased(), owner: String(segments[0]), name: String(segments[1]))
    }
}

struct PullRequestTarget: Hashable {
    /// Where the PR lives (the `upstream` remote in a fork workflow).
    let repository: GitRemote
    let branch: String
    /// Owner of the repository the branch is pushed to.
    let headOwner: String
}

struct RepoCheckout: Equatable {
    let root: String
    /// nil when HEAD is detached.
    let branch: String?
    /// `git config --get-regexp` entries; git lowercases section and
    /// variable names but keeps subsections (remote/branch names) as-is.
    let config: [String: String]

    /// Parses `git config -z` output: NUL-terminated `key\nvalue` records.
    /// A key with no value is skipped; a repeated key keeps the last value,
    /// matching git's own precedence.
    static func parseConfig(_ data: Data) -> [String: String] {
        var config: [String: String] = [:]
        for record in data.split(separator: 0) {
            guard let newline = record.firstIndex(of: UInt8(ascii: "\n")) else { continue }
            let key = String(decoding: record[record.startIndex..<newline], as: UTF8.self)
            let value = String(decoding: record[record.index(after: newline)...], as: UTF8.self)
            config[key] = value
        }
        return config
    }

    /// The head remote follows git's push precedence: the branch's
    /// `pushRemote`, then `remote.pushDefault`, then the branch's tracking
    /// remote, then `origin`. The PR's repository is `upstream` when that
    /// remote exists on the same host, else the head repository.
    func pullRequestTarget(supportedHosts: Set<String>) -> PullRequestTarget? {
        guard let branch else { return nil }
        let pushRemote = config["branch.\(branch).pushremote"]
            ?? config["remote.pushdefault"]
            ?? config["branch.\(branch).remote"]
            ?? "origin"
        guard let head = remote(named: pushRemote), supportedHosts.contains(head.host) else { return nil }
        let base = remote(named: "upstream").flatMap { $0.host == head.host ? $0 : nil } ?? head
        return PullRequestTarget(repository: base, branch: branch, headOwner: head.owner)
    }

    private func remote(named name: String) -> GitRemote? {
        config["remote.\(name).url"].flatMap(GitRemote.init(url:))
    }
}

struct PullRequestTargetPlan: Equatable {
    var targetsByPaneID: [String: PullRequestTarget]
    /// Distinct targets, in first-seen pane order.
    var targets: [PullRequestTarget]
    /// Distinct repositories -- one `gh pr list` each.
    var repositories: [GitRemote]
}

enum PullRequestTargetPlanner {
    /// `checkouts` maps a resolved directory to its checkout, or to nil when
    /// the directory isn't one; a pane whose directory is unknown, not yet
    /// resolved, or not a supported checkout gets no target.
    static func plan(
        panes: [Pane],
        checkouts: [String: RepoCheckout?],
        supportedHosts: Set<String>
    ) -> PullRequestTargetPlan {
        var plan = PullRequestTargetPlan(targetsByPaneID: [:], targets: [], repositories: [])
        for pane in panes {
            guard let directory = pane.workingDirectory,
                  let checkout = checkouts[directory] ?? nil,
                  let target = checkout.pullRequestTarget(supportedHosts: supportedHosts)
            else { continue }
            plan.targetsByPaneID[pane.id] = target
            if !plan.targets.contains(target) { plan.targets.append(target) }
            if !plan.repositories.contains(target.repository) { plan.repositories.append(target.repository) }
        }
        return plan
    }
}

struct RepoCheckoutCacheEntry: Equatable {
    let checkout: RepoCheckout?
    let resolvedAt: Date
}

struct RepoCheckoutCachePlan: Equatable {
    /// Directories to (re)resolve, in input order.
    var toResolve: [String]
    /// Cached directories no pane references any more.
    var toPrune: Set<String>
}

enum RepoCheckoutCachePlanner {
    /// A directory is resolved when first seen and again once its entry is
    /// older than `maxAge` -- the slow timer that notices a `git checkout`
    /// in a pane whose directory didn't change.
    static func plan(
        directories: [String],
        cache: [String: RepoCheckoutCacheEntry],
        now: Date,
        maxAge: TimeInterval
    ) -> RepoCheckoutCachePlan {
        var seen = Set<String>()
        var toResolve: [String] = []
        for directory in directories where seen.insert(directory).inserted {
            if let entry = cache[directory], now.timeIntervalSince(entry.resolvedAt) < maxAge { continue }
            toResolve.append(directory)
        }
        return RepoCheckoutCachePlan(toResolve: toResolve, toPrune: Set(cache.keys).subtracting(seen))
    }
}
