//
//  WorkspaceStartupPlanner.swift
//  Vakta
//
//  The pure startup decision `SessionStore.init` acts on: given what
//  `WorkspacePersistence.load` returned and the current profile list, which
//  sessions to recreate, which saved records couldn't be resolved to a
//  profile, which one to select, and whether the result needs writing back.
//  Kept separate from `SessionStore` (which owns process spawning and the
//  shared `TerminalController`) so the decision is testable without
//  constructing either.

import Foundation

/// A saved record matched to a still-existing profile, ready to recreate.
struct ResolvedSessionRecord: Equatable {
    var record: SessionRecord
    var profile: Profile
}

enum WorkspaceStartupDecision: Equatable {
    /// `toCreate` are records whose `profileID` matched a current profile --
    /// create exactly these, with `profile` (not a substituted default).
    /// `unresolved` are records whose profile no longer exists -- NOT
    /// launched under an unrelated profile; preserved for a future explicit
    /// recovery choice instead. `selectedSessionName` (if any of `toCreate`
    /// matches it) is the session to select after creation, overriding
    /// whichever one creation-order would otherwise leave selected.
    /// `shouldPersist` is true only when the in-memory result should replace
    /// what's on disk.
    case restore(
        toCreate: [ResolvedSessionRecord],
        unresolved: [SessionRecord],
        selectedSessionName: String?,
        shouldPersist: Bool
    )
}

enum WorkspaceStartupPlanner {
    /// - Missing (first launch): nothing to restore; persist that empty
    ///   result (so `SessionStore` seeding one default session is recorded).
    /// - Loaded: resolve each record against `profiles`, in saved order.
    ///   Already correct (or explicitly recoverable) on disk, so nothing
    ///   needs rewriting -- rewriting here would silently drop `unresolved`
    ///   records the user might otherwise recover by hand.
    /// - Corrupt/unreadable: restore nothing for this run, but do NOT
    ///   persist -- overwriting would permanently destroy a multi-session
    ///   workspace over what may be a transient read failure.
    static func plan(
        for outcome: FileLoadOutcome<WorkspacePayload>,
        profiles: [Profile]
    ) -> WorkspaceStartupDecision {
        switch outcome {
        case .missing:
            return .restore(toCreate: [], unresolved: [], selectedSessionName: nil, shouldPersist: true)

        case .loaded(let payload):
            var toCreate: [ResolvedSessionRecord] = []
            var unresolved: [SessionRecord] = []
            for record in payload.records {
                if let profile = profiles.first(where: { $0.id == record.profileID }) {
                    toCreate.append(ResolvedSessionRecord(record: record, profile: profile))
                } else {
                    unresolved.append(record)
                }
            }
            return .restore(
                toCreate: toCreate,
                unresolved: unresolved,
                selectedSessionName: payload.selectedSessionName,
                shouldPersist: false
            )

        case .corrupt, .unreadable:
            return .restore(toCreate: [], unresolved: [], selectedSessionName: nil, shouldPersist: false)
        }
    }
}
