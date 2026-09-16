//
//  HerdrPaneRegistry.swift
//  Vakta
//
//  Tracks whether a herdr session's known agent pane-id set changed since
//  the last `agent list` poll -- the only input `HerdrEventStreamClient`
//  needs to decide whether to reconnect with an updated subscription list
//  (confirmed in docs/herdr-events-plan.md: a live connection can't be
//  patched with a second `events.subscribe`). Deliberately holds no
//  per-pane status -- see the plan's design pivot: the event stream only
//  triggers the existing `pollAgentStatus()`, it never carries status data.

import Foundation

enum HerdrPaneRegistry {
    enum Update: Equatable {
        case unchanged
        case changed(paneIDs: Set<String>)
    }

    static func update(current: Set<String>, latest: Set<String>) -> Update {
        current == latest ? .unchanged : .changed(paneIDs: latest)
    }
}
