//
//  PollApplyPlanner.swift
//  Vakta
//
//  Pure decisions for what to keep from a completed background poll, given
//  what's actually live/current by the time the poll's result comes back.
//  `SessionStore` used to apply every raw result unconditionally: closing a
//  session while its status query was in flight didn't stop the query from
//  landing and resurrecting `agentStatus[id]` (and the Dock badge/
//  notification derived from it) for a session that no longer existed;
//  editing or deleting a profile while its discovery query was in flight
//  didn't stop that stale result from overwriting `discovered` for a target
//  that was no longer what the profile actually pointed at.

import Foundation

// MARK: Agent status

struct AgentStatusUpdate: Equatable {
    var sessionID: Session.ID
    var status: AgentStatus
}

/// One accepted update, paired with its previous value so the caller can
/// decide whether a transition notification is warranted.
struct AcceptedAgentStatusUpdate: Equatable {
    var sessionID: Session.ID
    var previous: AgentStatus?
    var status: AgentStatus
}

enum AgentStatusApplyPlanner {
    /// Keeps only updates for sessions still open by completion time -- a
    /// session removed while its query was in flight must not resurrect a
    /// status entry, Dock count, or notification for it.
    static func accepted(
        _ updates: [AgentStatusUpdate],
        liveSessionIDs: Set<Session.ID>,
        previous: [Session.ID: AgentStatus]
    ) -> [AcceptedAgentStatusUpdate] {
        updates
            .filter { liveSessionIDs.contains($0.sessionID) }
            .map { AcceptedAgentStatusUpdate(sessionID: $0.sessionID, previous: previous[$0.sessionID], status: $0.status) }
    }
}

// MARK: Discovery

/// One profile's discovery result, paired with the target it was actually
/// queried against.
struct DiscoveryQueryResult: Equatable {
    var profileID: Profile.ID
    var queriedTarget: LaunchTarget
    var result: DiscoveryResult
}

enum DiscoveryApplyPlanner {
    /// Keeps only results for profiles that still exist AND whose current
    /// resolved target still matches what was actually queried -- a profile
    /// deleted, or edited (command/arguments/environment changed) enough to
    /// resolve to a different target, while its query was in flight is
    /// dropped rather than applied as if it described the profile's current
    /// target.
    static func accepted(
        _ results: [DiscoveryQueryResult],
        currentProfiles: [Profile]
    ) -> [Profile.ID: DiscoveryResult] {
        var accepted: [Profile.ID: DiscoveryResult] = [:]
        for queryResult in results {
            guard let profile = currentProfiles.first(where: { $0.id == queryResult.profileID }) else { continue }
            guard LaunchTargetResolver.resolve(profile) == queryResult.queriedTarget else { continue }
            accepted[queryResult.profileID] = queryResult.result
        }
        return accepted
    }
}

// MARK: Dock badge

enum DockBadgePlanner {
    /// The Dock badge label derived from a snapshot of agent statuses: the
    /// count waiting on the user (`.attention`), or `nil` to clear it.
    static func label(for statuses: [AgentStatus]) -> String? {
        let waiting = statuses.lazy.filter { $0 == .attention }.count
        return waiting > 0 ? String(waiting) : nil
    }
}
