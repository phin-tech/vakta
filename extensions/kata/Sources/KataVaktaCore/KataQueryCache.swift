//
//  KataQueryCache.swift
//  KataVaktaCore
//
//  Issue queries per workspace, so one focus switch doesn't run `kata` for
//  the view, the Status Item and every Session's badge separately. The
//  focused project's entries are invalidated by its event stream; others
//  expire after `ttl`. Mutations clear everything.

import Foundation

public struct KataQueryCache {
    public enum Value: Equatable {
        case loaded(open: [KataIssue], readyIDs: Set<String>)
        case notInitialized
    }

    public var ttl: TimeInterval

    public init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    private struct Entry {
        var value: Value
        var storedAt: Date
        var projectID: Int? {
            if case .loaded(let open, _) = value { return open.first?.projectID }
            return nil
        }
    }

    private var entries: [String: Entry] = [:]

    public func value(for workspace: String, at now: Date) -> Value? {
        guard let entry = entries[workspace], now.timeIntervalSince(entry.storedAt) < ttl else { return nil }
        return entry.value
    }

    public mutating func store(_ value: Value, for workspace: String, at now: Date) {
        entries[workspace] = Entry(value: value, storedAt: now)
    }

    /// Drops entries of `projectID` (its events say they changed).
    public mutating func invalidate(projectID: Int) {
        entries = entries.filter { $0.value.projectID != projectID }
    }

    public mutating func invalidateAll() {
        entries.removeAll()
    }
}
