//
//  SingleFlightGate.swift
//  Vakta
//
//  Ensures at most one background query of a given kind is ever in flight.
//  `SessionStore.pollAgentStatus`/`refreshDiscovery` used to fire a new
//  DispatchQueue task on every timer tick with no regard for whether the
//  previous one had finished; if a poll's helper processes took longer than
//  the 2.5s tick interval, ticks piled up into an unbounded, ever-growing
//  set of concurrent background tasks all racing to write the same
//  published state on completion, in whatever order they happened to
//  finish -- not necessarily the order they started.
//
//  A tick that arrives while one is already in flight is simply dropped
//  (not queued, not merged) -- the next tick will try again. Since at most
//  one query is ever in flight, its completion can never race an older
//  one's: there is no older one.

import Foundation

@MainActor
final class SingleFlightGate {
    private(set) var isInFlight = false

    /// Call at the start of a would-be new query. Returns `true` (and marks
    /// this gate in-flight) if the caller should proceed; `false` if a
    /// previous query hasn't finished yet, in which case the caller must do
    /// nothing this tick.
    func beginIfIdle() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    /// Call once the in-flight query's result has been applied (or
    /// discarded), so the next tick is allowed to start one.
    func end() {
        isInFlight = false
    }
}
