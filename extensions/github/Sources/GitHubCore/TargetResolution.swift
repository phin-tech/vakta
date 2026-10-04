//
//  TargetResolution.swift
//  GitHubCore
//
//  Decides a pane's PullRequestTarget for the next Extension Context
//  snapshot. Kept pure and separate from the git config read (an I/O
//  concern the shell owns) so the decision is directly testable.

import Foundation

public enum TargetResolution {
    /// `resolved[paneID]`: `nil` when this snapshot has no gitRoot/branch to
    /// resolve from yet (info missing); `.some(nil)` when gitRoot/branch
    /// were available but resolved to no target; `.some(target)` otherwise.
    /// `previous` is the target map from the last snapshot.
    public static func next(
        resolved: [String: PullRequestTarget??], previous: [String: PullRequestTarget]
    ) -> [String: PullRequestTarget] {
        var result: [String: PullRequestTarget] = [:]
        for (paneID, value) in resolved {
            switch value {
            case .some(.some(let target)): result[paneID] = target
            case .some(.none): break
            case .none: if let kept = previous[paneID] { result[paneID] = kept }
            }
        }
        return result
    }
}
