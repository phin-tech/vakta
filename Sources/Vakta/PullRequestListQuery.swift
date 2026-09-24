//
//  PullRequestListQuery.swift
//  Vakta
//
//  Runs one `gh pr list` per repository and classifies the outcome. The
//  repository is passed explicitly (`--repo owner/name`) rather than relying
//  on gh's default-remote resolution from a working directory, which
//  `BoundedProcessRunner` doesn't set.

import Foundation

enum PullRequestListOutcome: Equatable {
    case pullRequests(PullRequestIndex)
    /// gh is not installed / not on PATH.
    case ghUnavailable
    /// gh is installed but has no usable login.
    case notAuthenticated
    /// Network or API failure, timeout, or cancellation -- worth retrying.
    case failed
    /// gh exited successfully with output that isn't a PR list.
    case malformed
}

enum PullRequestListQuery {
    static let jsonFields = "number,url,title,isDraft,headRefName,headRepositoryOwner,statusCheckRollup,reviewDecision,mergeStateStatus"

    /// `env`'s exit status when the command isn't found on PATH.
    private static let commandNotFoundExitCode: Int32 = 127
    /// gh's documented exit status when authentication is required.
    private static let authenticationRequiredExitCode: Int32 = 4

    static func arguments(repository: String, limit: Int) -> [String] {
        ["gh", "pr", "list", "--repo", repository, "--state", "open", "--limit", String(limit), "--json", jsonFields]
    }

    static func interpret(_ raw: ProcessRawResult, limit: Int) -> PullRequestListOutcome {
        if raw.launchFailed { return .ghUnavailable }
        if raw.cancelled || raw.timedOut { return .failed }
        switch raw.exitCode {
        case 0:
            guard let index = PullRequestIndex.parse(raw.stdout, limit: limit) else { return .malformed }
            return .pullRequests(index)
        case commandNotFoundExitCode:
            return .ghUnavailable
        case authenticationRequiredExitCode:
            return .notAuthenticated
        default:
            return .failed
        }
    }

    /// Blocks the calling thread for up to `timeout`; call it off the main
    /// actor. `environment` must carry gh's PATH and HOME (for its config
    /// and keychain-backed token).
    static func query(
        repository: String,
        environment: [String: String],
        limit: Int,
        timeout: TimeInterval,
        isCancelled: @escaping () -> Bool = { false }
    ) -> PullRequestListOutcome {
        let raw = BoundedProcessRunner.runRaw(
            executable: "/usr/bin/env",
            arguments: arguments(repository: repository, limit: limit),
            environment: environment,
            timeout: timeout,
            isCancelled: isCancelled
        )
        return interpret(raw, limit: limit)
    }
}
