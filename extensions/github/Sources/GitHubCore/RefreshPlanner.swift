//
//  RefreshPlanner.swift
//  GitHubCore
//
//  When each repository is due: the focused one every 30 s, others every
//  3 min, any with pending checks every 15 s, forced ones now; nothing while
//  GitHub's rate limit is spent. Intervals come from config.json.

import Foundation

public struct RefreshIntervals: Codable, Equatable, Sendable {
    public var focused: TimeInterval
    public var others: TimeInterval
    public var pending: TimeInterval

    public static let `default` = RefreshIntervals(focused: 30, others: 180, pending: 15)

    public init(focused: TimeInterval, others: TimeInterval, pending: TimeInterval) {
        self.focused = focused
        self.others = others
        self.pending = pending
    }

    /// Missing or unreadable config means the defaults; values are floored
    /// at 5 s so a typo can't hammer GitHub.
    public static func decode(_ data: Data?) -> RefreshIntervals {
        struct File: Decodable { var refresh: RefreshIntervals? }
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data), let refresh = file.refresh else { return .default }
        return RefreshIntervals(focused: max(5, refresh.focused), others: max(5, refresh.others), pending: max(5, refresh.pending))
    }
}

public enum RefreshPlanner {
    public static func interval(for repository: GitRemote, focused: Set<GitRemote>, pending: Set<GitRemote>, intervals: RefreshIntervals) -> TimeInterval {
        if pending.contains(repository) { return intervals.pending }
        if focused.contains(repository) { return intervals.focused }
        return intervals.others
    }

    /// Repositories to fetch now.
    public static func due(
        repositories: Set<GitRemote>, focused: Set<GitRemote>, pending: Set<GitRemote>, forced: Set<GitRemote>,
        lastFetched: [GitRemote: Date], now: Date, intervals: RefreshIntervals, rateLimitedUntil: Date?
    ) -> Set<GitRemote> {
        if let until = rateLimitedUntil, now < until { return [] }
        return repositories.filter { repository in
            if forced.contains(repository) { return true }
            guard let last = lastFetched[repository] else { return true }
            return now.timeIntervalSince(last) >= interval(for: repository, focused: focused, pending: pending, intervals: intervals)
        }
    }

    /// When the soonest repository falls due (to schedule the next wake).
    public static func nextDue(
        repositories: Set<GitRemote>, focused: Set<GitRemote>, pending: Set<GitRemote>,
        lastFetched: [GitRemote: Date], now: Date, intervals: RefreshIntervals, rateLimitedUntil: Date?
    ) -> Date? {
        let dates = repositories.map { repository -> Date in
            guard let last = lastFetched[repository] else { return now }
            return last.addingTimeInterval(interval(for: repository, focused: focused, pending: pending, intervals: intervals))
        }
        guard let soonest = dates.min() else { return nil }
        if let until = rateLimitedUntil, soonest < until { return until }
        return soonest
    }

    /// Back off when fewer than `floor` points remain: wait for the reset.
    public static func rateLimitedUntil(remaining: Int?, resetsAt: Date?, floor: Int = 50) -> Date? {
        guard let remaining, remaining < floor else { return nil }
        return resetsAt
    }
}
