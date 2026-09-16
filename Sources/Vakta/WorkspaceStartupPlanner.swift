//
//  WorkspaceStartupPlanner.swift
//  Vakta
//
//  The pure startup decision `SessionStore.init` acts on: given what
//  `WorkspacePersistence.load` returned, which records to restore and whether
//  the restored state needs writing back. Kept separate from `SessionStore`
//  (which owns process spawning and the shared `TerminalController`) so the
//  decision is testable without constructing either.

import Foundation

enum WorkspaceStartupDecision: Equatable {
    /// Restore `records` (empty means "one default session"). `shouldPersist`
    /// is true only when the in-memory result should replace what's on disk.
    case restore(records: [SessionRecord], shouldPersist: Bool)
}

enum WorkspaceStartupPlanner {
    /// - Missing (first launch): restore nothing (one default session) and
    ///   persist that single-session state.
    /// - Loaded: restore exactly what was saved; already correct on disk, so
    ///   nothing needs rewriting.
    /// - Corrupt/unreadable: restore nothing (one default session) for this
    ///   run, but do NOT persist -- overwriting would permanently destroy a
    ///   multi-session workspace over what may be a transient read failure.
    static func plan(for outcome: FileLoadOutcome<[SessionRecord]>) -> WorkspaceStartupDecision {
        switch outcome {
        case .missing:
            return .restore(records: [], shouldPersist: true)
        case .loaded(let records):
            return .restore(records: records, shouldPersist: false)
        case .corrupt, .unreadable:
            return .restore(records: [], shouldPersist: false)
        }
    }
}
