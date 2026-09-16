//
//  ProcessRunner.swift
//  Vakta
//
//  Runs a short-lived helper command with an explicit PATH (so tools resolve
//  under a `.app`'s minimal environment) and returns stdout. Shared by session
//  discovery and agent-status polling.

import Foundation

enum ProcessRunner {
    /// Runs `argv` via `/usr/bin/env` with `path` as PATH plus any
    /// `environment` overrides (e.g. a `MultiplexerTarget`'s server-selecting
    /// variables) layered on top of PATH/HOME. Returns stdout, or nil on
    /// launch failure, timeout, or non-zero exit.
    static func run(
        _ argv: [String],
        path: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 3
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.environment = environment.merging(
            ["PATH": path, "HOME": NSHomeDirectory()],
            uniquingKeysWith: { profileValue, _ in profileValue }
        )
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
