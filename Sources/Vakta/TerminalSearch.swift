//
//  TerminalSearch.swift
//  Vakta
//
//  Pure model of libghostty's scrollback search (libghostty-spm 2.2's
//  `TerminalSurfaceSearchDelegate`).

import Foundation

struct TerminalSearchState: Equatable {
    var isActive = false
    var needle = ""
    var total: Int?
    var selected: Int?

    enum Event: Equatable {
        case started(needle: String?)
        case ended
        case totalUpdated(Int?)
        case selectedUpdated(Int?)
        case needleEdited(String)
    }

    func applying(_ event: Event) -> TerminalSearchState {
        var next = self
        switch event {
        case let .started(seed):
            next.isActive = true
            if let seed { next.needle = seed }
        case .ended:
            next.isActive = false
            next.total = nil
            next.selected = nil
        case let .totalUpdated(total):
            if isActive { next.total = total }
        case let .selectedUpdated(selected):
            if isActive { next.selected = selected }
        case let .needleEdited(needle):
            // The counts belong to the old needle until the core reports again.
            next.needle = needle
            next.total = nil
            next.selected = nil
        }
        return next
    }

    /// "3/12", "No results", or "" while there is nothing to report.
    var summary: String {
        guard !needle.isEmpty, let total else { return "" }
        if total == 0 { return "No results" }
        // The core's selected index is zero-based.
        guard let selected else { return String(total) }
        return "\(selected + 1)/\(total)"
    }
}

enum TerminalSearchBindingAction {
    static func search(_ needle: String) -> String { "search:\(needle)" }
    static let next = "navigate_search:next"
    static let previous = "navigate_search:previous"
    static let end = "end_search"
}
