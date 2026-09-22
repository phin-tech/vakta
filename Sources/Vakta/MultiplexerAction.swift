//
//  MultiplexerAction.swift
//  Vakta
//
//  The mutating layout/session commands Vakta exposes to the sidebar context
//  menu and the ⌘K palette (split, close, zoom, resize a pane; create,
//  rename, close a workspace). A new capability class alongside the existing
//  read-oriented queries (`SessionDiscovery`, `WorkspaceQuery`, `PaneQuery`):
//  the pure `MultiplexerAction` names the intent, `MultiplexerTarget.actionArgv`
//  vends the per-backend argv (returning `nil` where a backend has no
//  equivalent), and `MultiplexerCommand` is the shell that runs it -- the same
//  grain as `WorkspaceFocus`.
//
//  Every v1 action maps to a one-shot CLI invocation for both herdr and tmux
//  (herdr's `pane`/`workspace` subcommands accept explicit ids; tmux's
//  `split-window`/`kill-pane`/... take a target), so no socket adapter is
//  needed here -- the herdr socket path (see `HerdrPaneFocus`) stays reserved
//  for the by-id ops the CLI can't express.

import Foundation

/// Which way a `splitPane` divides the target pane. herdr and tmux both only
/// split along these two axes from the CLI.
enum SplitDirection: Equatable {
    case right
    case down
}

/// The edge a `resizePane` grows toward. The magnitude is deliberately not
/// part of the action: the two backends use incompatible units (herdr a
/// split-ratio delta, tmux whole terminal cells), so `actionArgv` bakes a
/// sensible per-backend step. A menu "grow/shrink" button only needs the
/// direction.
enum ResizeDirection: Equatable {
    case left
    case right
    case up
    case down
}

/// A mutating multiplexer command targeting a specific pane or workspace the
/// caller already enumerated (via `PaneQuery`/`WorkspaceQuery`). Ids are the
/// backend's own opaque handles -- herdr `w2C`/`w2C:p3`, tmux `@1`/`%3`.
enum MultiplexerAction: Equatable {
    case splitPane(paneID: String, direction: SplitDirection)
    case closePane(paneID: String)
    case zoomPane(paneID: String)
    case resizePane(paneID: String, direction: ResizeDirection)
    case renamePane(paneID: String, label: String)
    case closeWorkspace(workspaceID: String)
    case createWorkspace(label: String?)
    case renameWorkspace(workspaceID: String, label: String)
    /// Stop the whole named session at the server (herdr `session stop`, tmux
    /// `kill-session`) -- distinct from Vakta's own detach, which only closes
    /// the local view while the server session persists.
    case stopSession
}

/// Runs a `MultiplexerAction` against its target. Mirrors `WorkspaceFocus`:
/// build the backend argv, run it with the target's executable/environment,
/// and report success. The caller owns dispatching this off the main actor
/// and refetching topology afterward (a Vakta-initiated mutation is not
/// observed by the workspace-refresh monitor).
enum MultiplexerCommand {
    static func run(
        action: MultiplexerAction,
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Bool {
        guard !isCancelled(),
              let argv = target.actionArgv(sessionName: sessionName, action)
        else { return false }
        return ProcessRunner.run(
            argv,
            path: path,
            environment: target.environment,
            isCancelled: isCancelled
        ) != nil
    }
}
