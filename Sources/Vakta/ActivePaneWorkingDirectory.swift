//
//  ActivePaneWorkingDirectory.swift
//  Vakta
//
//  Multiplexer-backend capability #7 (docs/multiplexer-backends.md): the
//  currently focused pane's working directory, for "Open in Editor". Built
//  on `BoundedProcessRunner.runRaw` directly, NOT `ProcessRunner` --
//  `ProcessRunner.run` discards stdout on any non-zero exit (see its own
//  doc comment), but herdr writes its error envelope to stdout WITH exit
//  code 1 (confirmed live: `server_not_running`). Reading raw stdout
//  regardless of exit code is what lets `.serverNotRunning`/`.error` survive
//  at all instead of collapsing into `.malformed`.

import Foundation

enum ActivePaneWorkingDirectoryResult: Equatable {
    case workingDirectory(String)
    case serverNotRunning
    case error(code: String)
    case malformed
}

enum ActivePaneWorkingDirectoryQuery {
    /// Queries `sessionName`'s currently focused pane's working directory on
    /// `target`'s server. `nil` when `target`'s backend has no equivalent
    /// (none currently -- herdr and tmux both cover it -- but kept `nil`-
    /// returning for symmetry with `workspaceListArgv`/`statusArgv`).
    static func query(
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> ActivePaneWorkingDirectoryResult? {
        guard let argv = target.activePaneWorkingDirectoryArgv(sessionName: sessionName) else { return nil }
        let raw = BoundedProcessRunner.runRaw(
            executable: "/usr/bin/env",
            arguments: argv,
            environment: target.environment.merging(
                ["PATH": path, "HOME": NSHomeDirectory()],
                uniquingKeysWith: { profileValue, _ in profileValue }
            ),
            timeout: 3,
            isCancelled: isCancelled
        )
        guard let output = String(data: raw.stdout, encoding: .utf8), !output.isEmpty else { return .malformed }
        return parse(output, backend: target.backend)
    }

    /// Dispatches on the target's backend to the matching output parser.
    static func parse(_ output: String, backend: MultiplexerTarget.Backend) -> ActivePaneWorkingDirectoryResult {
        switch backend {
        case .herdr: return parseHerdr(output)
        case .tmux: return parseTmux(output)
        }
    }

    /// `herdr pane current`'s envelope: `result.pane` on success, `error` on
    /// failure. `foreground_cwd` (the foreground process's directory, e.g.
    /// inside vim) wins over `cwd` (the shell's own) when both are present.
    private static func parseHerdr(_ output: String) -> ActivePaneWorkingDirectoryResult {
        guard let data = output.data(using: .utf8), let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return .malformed
        }
        if let pane = decoded.result?.pane, let path = pane.foreground_cwd ?? pane.cwd {
            return .workingDirectory(path)
        }
        if let error = decoded.error {
            return error.code == "server_not_running" ? .serverNotRunning : .error(code: error.code)
        }
        return .malformed
    }

    /// `display-message -p ... '#{pane_current_path}'`: a single line.
    private static func parseTmux(_ output: String) -> ActivePaneWorkingDirectoryResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .malformed }
        return .workingDirectory(trimmed)
    }

    private struct Response: Decodable {
        let result: Result?
        let error: ErrorPayload?
        struct Result: Decodable { let pane: Pane }
        struct Pane: Decodable {
            let cwd: String?
            let foreground_cwd: String?
        }
        struct ErrorPayload: Decodable { let code: String }
    }
}
