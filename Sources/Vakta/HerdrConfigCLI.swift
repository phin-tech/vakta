//
//  HerdrConfigCLI.swift
//  Vakta
//
//  The two `herdr` commands the config editor shells out to: `config check`
//  (validate a candidate file, pointed at a temp copy via HERDR_CONFIG_PATH so
//  the live file is never touched) and `server reload-config`. Blocking; the
//  store runs them off the main actor.

import Foundation

private enum HerdrCLI {
    /// `/usr/bin/env` reports a missing executable as exit 126/127 rather
    /// than a launch failure.
    static func isMissingExecutable(_ raw: ProcessRawResult) -> Bool {
        raw.launchFailed || raw.exitCode == 126 || raw.exitCode == 127
    }

    static func run(
        command: [String], subcommand: [String], path: String,
        environment: [String: String], timeout: TimeInterval = 5
    ) -> ProcessRawResult {
        BoundedProcessRunner.runRaw(
            executable: "/usr/bin/env",
            arguments: command + subcommand,
            environment: environment.merging(
                ["PATH": path, "HOME": NSHomeDirectory()], uniquingKeysWith: { _, required in required }),
            timeout: timeout
        )
    }
}

struct HerdrConfigChecker {
    /// argv prefix that runs herdr, e.g. `["herdr"]` (resolved via PATH).
    let herdrCommand: [String]
    let path: String
    var environment: [String: String] = [:]

    func check(candidate: String) -> HerdrConfigCheckResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vakta-herdr-check-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try candidate.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return .unavailable
        }

        let raw = HerdrCLI.run(
            command: herdrCommand,
            subcommand: ["config", "check"],
            path: path,
            environment: environment.merging(["HERDR_CONFIG_PATH": file.path], uniquingKeysWith: { _, required in required })
        )
        if HerdrCLI.isMissingExecutable(raw) || raw.timedOut || raw.cancelled { return .unavailable }
        if raw.exitCode == 0 { return .valid }

        let output = String(decoding: raw.stdout, as: UTF8.self)
        let diagnostics = HerdrConfigDiagnostic.parse(checkOutput: output)
        if !diagnostics.isEmpty { return .invalid(diagnostics) }
        return .invalid([HerdrConfigDiagnostic(
            line: 0, column: 0, message: output.trimmingCharacters(in: .whitespacesAndNewlines))])
    }
}

enum HerdrConfigReloadOutcome: Equatable {
    case reloaded
    case failed(String)
}

struct HerdrConfigReloader {
    let herdrCommand: [String]
    let path: String
    var environment: [String: String] = [:]

    func reload() -> HerdrConfigReloadOutcome {
        let raw = HerdrCLI.run(
            command: herdrCommand, subcommand: ["server", "reload-config"],
            path: path, environment: environment)
        if HerdrCLI.isMissingExecutable(raw) { return .failed("herdr could not be run") }
        if raw.timedOut { return .failed("herdr timed out reloading its config") }
        if raw.exitCode == 0 { return .reloaded }
        return .failed("herdr server reload-config exited with status \(raw.exitCode ?? -1)")
    }
}
