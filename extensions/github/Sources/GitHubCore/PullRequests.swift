//
//  PullRequests.swift
//  GitHubCore
//
//  A pull request's state as Vakta shows it (ported from the former
//  built-in): checks collapse worst-of, review decision, merge state, and
//  one overall state ordered worst first.

import Foundation

public struct PullRequestCheck: Equatable, Sendable {
    public enum State: Equatable, Sendable { case passing, failing, pending }

    public let name: String
    public let state: State
    public let url: String?

    public init(name: String, state: State, url: String?) {
        self.name = name
        self.state = state
        self.url = url
    }

    /// A check run (`status` + `conclusion`) or a commit status (`state`).
    public static func state(status: String?, conclusion: String?, state: String?) -> State {
        if let status {
            guard status.uppercased() == "COMPLETED" else { return .pending }
            switch conclusion?.uppercased() {
            case "SUCCESS", "NEUTRAL", "SKIPPED": return .passing
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failing
            default: return .pending
            }
        }
        switch state?.uppercased() {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        default: return .pending
        }
    }
}

public enum PullRequestReview: Equatable, Sendable {
    case approved, changesRequested, reviewRequired

    public init?(gitHubDecision: String?) {
        switch gitHubDecision?.uppercased() {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: return nil
        }
    }
}

public enum PullRequestMergeState: Equatable, Sendable {
    case ready, blocked, behind, conflicts, unstable, draft, unknown

    public init(gitHubStatus: String?) {
        switch gitHubStatus?.uppercased() {
        case "CLEAN", "HAS_HOOKS": self = .ready
        case "BLOCKED": self = .blocked
        case "BEHIND": self = .behind
        case "DIRTY": self = .conflicts
        case "UNSTABLE": self = .unstable
        case "DRAFT": self = .draft
        default: self = .unknown
        }
    }
}

/// The one state shown for a PR, worst first.
public enum PullRequestState: Int, Comparable, Sendable {
    case failing, changesRequested, pending, noChecks, passing, readyToMerge

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PullRequest: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let url: String
    public let isDraft: Bool
    public let headBranch: String
    public let headOwner: String
    public let checks: [PullRequestCheck]
    public let review: PullRequestReview?
    public let mergeState: PullRequestMergeState

    public init(
        number: Int, title: String, url: String, isDraft: Bool, headBranch: String, headOwner: String,
        checks: [PullRequestCheck], review: PullRequestReview?, mergeState: PullRequestMergeState
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.headBranch = headBranch
        self.headOwner = headOwner
        self.checks = checks
        self.review = review
        self.mergeState = mergeState
    }

    public var passing: Int { checks.filter { $0.state == .passing }.count }
    public var failing: Int { checks.filter { $0.state == .failing }.count }
    public var pending: Int { checks.filter { $0.state == .pending }.count }

    /// Worst first: failing checks, changes requested, pending checks, then
    /// mergeable now, then passing checks or an approval.
    public var state: PullRequestState {
        if failing > 0 { return .failing }
        if review == .changesRequested { return .changesRequested }
        if pending > 0 { return .pending }
        if mergeState == .ready { return .readyToMerge }
        if passing > 0 || review == .approved { return .passing }
        return .noChecks
    }

    /// Failing, then pending, then passing; alphabetical within each.
    public var orderedChecks: [PullRequestCheck] {
        func rank(_ state: PullRequestCheck.State) -> Int {
            switch state {
            case .failing: return 0
            case .pending: return 1
            case .passing: return 2
            }
        }
        return checks.sorted {
            rank($0.state) != rank($1.state)
                ? rank($0.state) < rank($1.state)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
