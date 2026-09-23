//
//  FileRowClickPlanner.swift
//  Vakta
//
//  What a click on a file sidebar row does. Rows handle every click as it
//  arrives, using the event's click count, instead of pairing a single-tap
//  and a double-tap gesture: SwiftUI holds a single tap back for the whole
//  double-click interval to rule out a double, which made every expand and
//  collapse lag.
//

enum FileRowClickAction: Equatable {
    case select
    case toggleExpansion
    case open
}

enum FileRowClickPlanner {
    /// Every click also selects the row. A directory toggles on the first
    /// click only (a second click would undo it); a file opens on the second.
    static func action(clickCount: Int, isDirectory: Bool, canOpen: Bool) -> FileRowClickAction {
        switch (clickCount, isDirectory) {
        case (1, true): return .toggleExpansion
        case (2, false) where canOpen: return .open
        default: return .select
        }
    }
}
