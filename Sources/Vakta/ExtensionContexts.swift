//
//  ExtensionContexts.swift
//  Vakta
//
//  Builds the Extension Context for every Session: its stable Session Key,
//  active pane working directory, git root and branch, focused Workspace and
//  whether it's focused. `ExtensionContextPlanner` is pure; the gatherer runs
//  the multiplexer and git queries (blocking: call it off the main actor).

import Foundation
import VaktaExtensionKit

/// What the shell knows about one Session, snapshotted on the main actor.
struct ExtensionSessionInput: Equatable {
    var sessionID: UUID
    /// `nil` for a Session without a multiplexer (a plain shell).
    var target: MultiplexerTarget?
    var sessionName: String
    var terminalReportedWorkingDirectory: String?
    var profileWorkingDirectory: String?
    var focusedWorkspace: Workspace?
    var focused: Bool
}

enum ExtensionContextPlanner {
    /// Backend plus multiplexer session name, stable across Vakta restarts.
    /// A plain shell has no multiplexer name, so it falls back to Vakta's
    /// per-launch id: Extensions can't remember those across restarts.
    static func sessionKey(backend: MultiplexerTarget.Backend?, sessionName: String, sessionID: UUID) -> SessionKey {
        switch backend {
        case .herdr?: return SessionKey(backend: "herdr", sessionName: sessionName)
        case .tmux?: return SessionKey(backend: "tmux", sessionName: sessionName)
        case nil: return SessionKey(backend: "shell", sessionName: sessionID.uuidString)
        }
    }

    /// The working directory follows "Open in Editor"'s precedence
    /// (`WorkingDirectoryResolver`).
    static func workingDirectory(
        for input: ExtensionSessionInput, multiplexerWorkingDirectory: ActivePaneWorkingDirectoryResult?
    ) -> String? {
        WorkingDirectoryResolver.resolve(
            multiplexerResult: multiplexerWorkingDirectory,
            terminalReportedWorkingDirectory: input.terminalReportedWorkingDirectory,
            profileWorkingDirectory: input.profileWorkingDirectory
        )
    }

    static func context(
        for input: ExtensionSessionInput,
        multiplexerWorkingDirectory: ActivePaneWorkingDirectoryResult?,
        checkout: RepoCheckout?
    ) -> ExtensionContext {
        ExtensionContext(
            sessionKey: sessionKey(backend: input.target?.backend, sessionName: input.sessionName, sessionID: input.sessionID),
            cwd: workingDirectory(for: input, multiplexerWorkingDirectory: multiplexerWorkingDirectory),
            gitRoot: checkout?.root,
            branch: checkout?.branch,
            workspace: input.focusedWorkspace.map { WorkspaceRef(id: $0.id, label: $0.label) },
            focused: input.focused
        )
    }
}

enum ExtensionContextGatherer {
    /// Blocks on one multiplexer query and up to three git runs per Session.
    static func gather(_ inputs: [ExtensionSessionInput], path: String) -> [ExtensionContext] {
        let environment = ["PATH": path, "HOME": NSHomeDirectory()]
        return inputs.map { input in
            let multiplexer = input.target.flatMap {
                ActivePaneWorkingDirectoryQuery.query(sessionName: input.sessionName, target: $0, path: path)
            }
            let cwd = ExtensionContextPlanner.workingDirectory(for: input, multiplexerWorkingDirectory: multiplexer)
            let checkout = cwd.flatMap { RepoCheckoutQuery.query(directory: $0, environment: environment) }
            return ExtensionContextPlanner.context(for: input, multiplexerWorkingDirectory: multiplexer, checkout: checkout)
        }
    }
}
