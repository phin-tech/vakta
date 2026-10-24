//
//  TerminalSearchModel.swift
//  Vakta
//
//  One session's scrollback-search state. libghostty reports the search
//  through `TerminalSurfaceSearchDelegate`; typing, stepping and closing go
//  back as binding actions via `send`. The decisions live in
//  `TerminalSearchState`; this class only owns the observable value.

import Combine
import GhosttyTerminal

@MainActor
final class TerminalSearchModel: ObservableObject, TerminalSurfaceSearchDelegate {
    @Published private(set) var state = TerminalSearchState()

    /// Hands a binding action to the session's surface.
    var send: (String) -> Void = { _ in }

    func edit(_ needle: String) {
        state = state.applying(.needleEdited(needle))
        send(TerminalSearchBindingAction.search(needle))
    }

    func next() { send(TerminalSearchBindingAction.next) }
    func previous() { send(TerminalSearchBindingAction.previous) }

    func close() {
        state = state.applying(.ended)
        send(TerminalSearchBindingAction.end)
    }

    func terminalDidStartSearch(needle: String?) { state = state.applying(.started(needle: needle)) }
    func terminalDidEndSearch() { state = state.applying(.ended) }
    func terminalDidUpdateSearchTotal(_ total: Int?) { state = state.applying(.totalUpdated(total)) }
    func terminalDidUpdateSearchSelected(_ selected: Int?) { state = state.applying(.selectedUpdated(selected)) }
}
