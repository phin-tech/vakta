//
//  PullRequestIndex.swift
//  Vakta
//
//  Pure decoding and decisions for PR status: one `gh pr list` response per
//  repository becomes an index that every pane on any branch of that repo
//  can be matched against, so lookup cost scales with repositories, not
//  panes. The check rollup keeps roux's `summarize_checks` worst-of
//  semantics (`../roux/src-tauri/src/pr.rs`).

import Foundation

enum PullRequestReview: Equatable {
    case approved
    case changesRequested
    case reviewRequired

    /// GitHub's `reviewDecision`; gh reports `""` when there is none.
    /// Unknown values are nil so a new GitHub state shows nothing rather
    /// than a wrong glyph.
    init?(gitHubDecision: String?) {
        switch gitHubDecision?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: return nil
        }
    }
}

/// One row of gh's `statusCheckRollup`. gh mixes two shapes: workflow check
/// runs (`status` + `conclusion`) and commit-status contexts (`state`).
struct PullRequestCheckRow: Equatable {
    var status: String?
    var conclusion: String?
    var state: String?
}

struct PullRequestChecks: Equatable {
    enum State: Equatable {
        case none
        case passing
        case pending
        case failing
    }

    var passing: Int
    var failing: Int
    var pending: Int

    var total: Int { passing + failing + pending }

    /// Worst-of: any failure fails, else anything unsettled is pending, else
    /// passing; an empty rollup is `.none`.
    var state: State {
        if failing > 0 { return .failing }
        if pending > 0 { return .pending }
        if passing > 0 { return .passing }
        return .none
    }

    static func summarize(_ rows: [PullRequestCheckRow]) -> PullRequestChecks {
        var checks = PullRequestChecks(passing: 0, failing: 0, pending: 0)
        for row in rows {
            switch classify(row) {
            case .passing: checks.passing += 1
            case .failing: checks.failing += 1
            case .pending: checks.pending += 1
            }
        }
        return checks
    }

    private enum RowClass { case passing, failing, pending }

    /// Unknown values count as pending -- better to under-promise than to
    /// flash green while a check is still running.
    private static func classify(_ row: PullRequestCheckRow) -> RowClass {
        if let status = row.status {
            // A check run is settled only once COMPLETED; before that its
            // conclusion is empty.
            guard status.uppercased() == "COMPLETED" else { return .pending }
            switch row.conclusion?.uppercased() {
            case "SUCCESS", "NEUTRAL", "SKIPPED": return .passing
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failing
            default: return .pending
            }
        }
        switch row.state?.uppercased() {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        default: return .pending
        }
    }
}

struct PullRequestStatus: Equatable {
    let number: Int
    let url: String
    let title: String
    let isDraft: Bool
    let headBranch: String
    /// The login owning the PR's head repository -- distinguishes a fork's
    /// same-named branch from the local one.
    let headOwner: String
    let checks: PullRequestChecks
    let review: PullRequestReview?
}

struct PullRequestIndex: Equatable {
    let pullRequests: [PullRequestStatus]
    /// False when the result count reached the requested `--limit`, so a
    /// branch missing from the index may still have an open PR.
    let isComplete: Bool

    /// The open PR whose head is `branch` in `headOwner`'s repository
    /// (owner compared case-insensitively, as GitHub logins are).
    func pullRequest(branch: String, headOwner: String) -> PullRequestStatus? {
        pullRequests.first {
            $0.headBranch == branch && $0.headOwner.caseInsensitiveCompare(headOwner) == .orderedSame
        }
    }

    /// Decodes a `gh pr list --json …` array. An entry missing a required
    /// field is dropped on its own; anything other than an array is nil.
    static func parse(_ data: Data, limit: Int) -> PullRequestIndex? {
        guard let entries = try? JSONDecoder().decode([Lossy<Wire>].self, from: data) else { return nil }
        let pullRequests = entries.compactMap { $0.value?.status }
        return PullRequestIndex(pullRequests: pullRequests, isComplete: entries.count < limit)
    }

    /// Decodes an element, or records nil instead of failing the array.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct Wire: Decodable {
        struct Owner: Decodable { let login: String }
        struct CheckRow: Decodable {
            let status: String?
            let conclusion: String?
            let state: String?
        }

        let number: Int
        let url: String
        let title: String?
        let isDraft: Bool?
        let headRefName: String
        let headRepositoryOwner: Owner
        let statusCheckRollup: [CheckRow]?
        let reviewDecision: String?

        var status: PullRequestStatus {
            PullRequestStatus(
                number: number,
                url: url,
                title: title ?? "",
                isDraft: isDraft ?? false,
                headBranch: headRefName,
                headOwner: headRepositoryOwner.login,
                checks: .summarize((statusCheckRollup ?? []).map {
                    PullRequestCheckRow(status: $0.status, conclusion: $0.conclusion, state: $0.state)
                }),
                review: PullRequestReview(gitHubDecision: reviewDecision)
            )
        }
    }
}
