//
//  Remotes.swift
//  GitHubCore
//
//  Which repository a branch's pull request lives in, from the checkout's
//  git config (ported from Vakta's former built-in PR status): the head
//  remote follows git's push precedence, and the PR's repository is
//  `upstream` when that remote exists on the same host.

import Foundation

/// A GitHub-style remote: host plus exactly `owner/name`.
public struct GitRemote: Hashable, Sendable {
    public let host: String
    public let owner: String
    public let name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// `owner/name` on github.com, `host/owner/name` elsewhere.
    public var slug: String { host == "github.com" ? "\(owner)/\(name)" : "\(host)/\(owner)/\(name)" }

    /// URL forms (`ssh://`, `https://`, `git://`, optional user and port)
    /// and scp-style `[user@]host:owner/name`, with or without `.git`.
    public init?(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(), ["ssh", "https", "http", "git"].contains(scheme),
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

/// A branch's PR lookup key.
public struct PullRequestTarget: Hashable, Sendable {
    /// Where the PR lives (`upstream` in a fork workflow).
    public let repository: GitRemote
    public let branch: String
    /// Owner of the repository the branch is pushed to.
    public let headOwner: String

    public init(repository: GitRemote, branch: String, headOwner: String) {
        self.repository = repository
        self.branch = branch
        self.headOwner = headOwner
    }
}

public enum RepoConfig {
    /// `git config -z --get-regexp` output: NUL-terminated `key\nvalue`.
    public static func parse(_ data: Data) -> [String: String] {
        var config: [String: String] = [:]
        for record in data.split(separator: 0) {
            guard let newline = record.firstIndex(of: UInt8(ascii: "\n")) else { continue }
            config[String(decoding: record[record.startIndex..<newline], as: UTF8.self)] =
                String(decoding: record[record.index(after: newline)...], as: UTF8.self)
        }
        return config
    }

    /// The config keys `target` reads.
    public static let pattern = #"^(remote\..*\.url|remote\.pushdefault|branch\..*\.(remote|pushremote))$"#

    public static func target(config: [String: String], branch: String, supportedHosts: Set<String>) -> PullRequestTarget? {
        let pushRemote = config["branch.\(branch).pushremote"] ?? config["remote.pushdefault"]
            ?? config["branch.\(branch).remote"] ?? "origin"
        func remote(_ name: String) -> GitRemote? { config["remote.\(name).url"].flatMap(GitRemote.init(url:)) }
        guard let head = remote(pushRemote), supportedHosts.contains(head.host) else { return nil }
        let base = remote("upstream").flatMap { $0.host == head.host ? $0 : nil } ?? head
        return PullRequestTarget(repository: base, branch: branch, headOwner: head.owner)
    }
}
