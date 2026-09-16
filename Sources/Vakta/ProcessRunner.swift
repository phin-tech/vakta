//
//  ProcessRunner.swift
//  Vakta
//
//  Runs a short-lived helper command with an explicit PATH (so tools resolve
//  under a `.app`'s minimal environment) and returns stdout. Shared by session
//  discovery and agent-status polling. A thin `String?`-returning wrapper
//  over `BoundedProcessRunner` (which distinguishes every failure mode);
//  callers here have never needed more than "did it work."

import Foundation

enum ProcessRunner {
    /// Runs `argv` via `/usr/bin/env` with `path` as PATH plus any
    /// `environment` overrides (e.g. a `MultiplexerTarget`'s server-selecting
    /// variables) layered on top of PATH/HOME. Returns stdout, or nil on
    /// launch failure, timeout, non-zero exit, or invalid UTF-8.
    static func run(
        _ argv: [String],
        path: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 3,
        isCancelled: @escaping () -> Bool = { false }
    ) -> String? {
        let result = BoundedProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: argv,
            environment: environment.merging(
                ["PATH": path, "HOME": NSHomeDirectory()],
                uniquingKeysWith: { profileValue, _ in profileValue }
            ),
            timeout: timeout,
            isCancelled: isCancelled
        )
        guard case .success(let output) = result else { return nil }
        return output
    }
}
