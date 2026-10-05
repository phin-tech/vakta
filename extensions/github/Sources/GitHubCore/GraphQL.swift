//
//  GraphQL.swift
//  GitHubCore
//
//  One GraphQL request covers every repository and branch in view: each
//  repository is an aliased field (`r0`, `r1`, …) and each branch an aliased
//  `pullRequests(headRefName:)` inside it. The response is matched back to
//  targets by alias, and a PR counts only when its head owner matches (a
//  fork's same-named branch isn't yours).

import Foundation

public struct PullRequestQuery: Equatable, Sendable {
    /// GraphQL text sent as `{"query": …}`.
    public let text: String
    /// Alias path (`r0.b1`) → target.
    public let targets: [String: PullRequestTarget]

    /// All targets must share one host (one request per GitHub host).
    public init(targets: [PullRequestTarget]) {
        var byRepository: [GitRemote: [PullRequestTarget]] = [:]
        var order: [GitRemote] = []
        for target in targets {
            if byRepository[target.repository] == nil { order.append(target.repository) }
            if !(byRepository[target.repository] ?? []).contains(target) { byRepository[target.repository, default: []].append(target) }
        }
        var map: [String: PullRequestTarget] = [:]
        var fields: [String] = []
        for (repositoryIndex, repository) in order.enumerated() {
            var branches: [String] = []
            for (branchIndex, target) in (byRepository[repository] ?? []).enumerated() {
                map["r\(repositoryIndex).b\(branchIndex)"] = target
                branches.append("b\(branchIndex): pullRequests(headRefName: \(Self.literal(target.branch)), states: OPEN, first: 10) { nodes { ...pr } }")
            }
            fields.append("r\(repositoryIndex): repository(owner: \(Self.literal(repository.owner)), name: \(Self.literal(repository.name))) { \(branches.joined(separator: " ")) }")
        }
        text = "query { \(fields.joined(separator: " ")) rateLimit { remaining resetAt } }\n" + Self.fragment
        self.targets = map
    }

    /// A GraphQL string literal (JSON string escaping is valid GraphQL).
    static func literal(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    static let fragment = """
        fragment pr on PullRequest {
          number title url isDraft headRefName reviewDecision mergeStateStatus
          headRepositoryOwner { login }
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name status conclusion detailsUrl }
            ... on StatusContext { context state targetUrl }
          } } } } } }
        }
        """
}

public struct PullRequestResult: Equatable, Sendable {
    /// Every queried target → its open PR (nil when it has none).
    public var pullRequests: [PullRequestTarget: PullRequest?]
    public var rateRemaining: Int?
    public var rateResetsAt: Date?
}

public enum PullRequestResponseError: Error, Equatable {
    case unauthorized
    case rateLimited(resetsAt: Date?)
    case malformed
    case graphQL(String)
}

public enum PullRequestResponse {
    /// Decodes a GraphQL response body for `query`.
    public static func parse(_ data: Data, for query: PullRequestQuery) -> Result<PullRequestResult, PullRequestResponseError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.malformed) }
        if let message = object["message"] as? String, object["data"] == nil {
            return .failure(message.lowercased().contains("bad credentials") ? .unauthorized : .graphQL(message))
        }
        let errors = (object["errors"] as? [[String: Any]]) ?? []
        if errors.contains(where: { ($0["type"] as? String) == "RATE_LIMITED" }) {
            return .failure(.rateLimited(resetsAt: nil))
        }
        guard let root = object["data"] as? [String: Any] else {
            return .failure(.graphQL((errors.first?["message"] as? String) ?? "GitHub returned no data."))
        }
        // A field-level error (one aliased repository/branch failed inside an
        // otherwise-successful response) leaves that field null; without this,
        // it reads as GitHub confirming no open PR, overwriting a previously
        // known one and flickering the panel every time it recurs.
        let erroredPaths: [[String]] = errors.compactMap { ($0["path"] as? [Any])?.compactMap { $0 as? String } }
        func erroredAlias(_ parts: [String]) -> Bool {
            erroredPaths.contains { path in
                let shared = min(path.count, parts.count)
                return shared > 0 && Array(path.prefix(shared)) == Array(parts.prefix(shared))
            }
        }
        var result = PullRequestResult(pullRequests: [:], rateRemaining: nil, rateResetsAt: nil)
        if let rate = root["rateLimit"] as? [String: Any] {
            result.rateRemaining = rate["remaining"] as? Int
            result.rateResetsAt = (rate["resetAt"] as? String).flatMap(ISO8601DateFormatter().date(from:))
        }
        for (alias, target) in query.targets {
            let parts = alias.split(separator: ".").map(String.init)
            guard !erroredAlias(parts) else { continue }
            let nodes = ((root[parts[0]] as? [String: Any])?[parts[1]] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            let match = nodes.compactMap(pullRequest).first {
                $0.headBranch == target.branch && $0.headOwner.caseInsensitiveCompare(target.headOwner) == .orderedSame
            }
            result.pullRequests[target] = .some(match)
        }
        return .success(result)
    }

    static func pullRequest(_ node: [String: Any]) -> PullRequest? {
        guard let number = node["number"] as? Int, let title = node["title"] as? String, let url = node["url"] as? String,
              let headBranch = node["headRefName"] as? String
        else { return nil }
        let rollup = ((((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any])?[
            "statusCheckRollup"] as? [String: Any])
        let contexts = ((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let checks = contexts.map { context -> PullRequestCheck in
            let name = (context["name"] as? String) ?? (context["context"] as? String) ?? "Unnamed check"
            return PullRequestCheck(
                name: name,
                state: PullRequestCheck.state(status: context["status"] as? String, conclusion: context["conclusion"] as? String,
                                              state: context["state"] as? String),
                url: (context["detailsUrl"] as? String) ?? (context["targetUrl"] as? String)
            )
        }
        return PullRequest(
            number: number, title: title, url: url, isDraft: (node["isDraft"] as? Bool) ?? false, headBranch: headBranch,
            headOwner: ((node["headRepositoryOwner"] as? [String: Any])?["login"] as? String) ?? "",
            checks: checks, review: PullRequestReview(gitHubDecision: node["reviewDecision"] as? String),
            mergeState: PullRequestMergeState(gitHubStatus: node["mergeStateStatus"] as? String)
        )
    }
}
