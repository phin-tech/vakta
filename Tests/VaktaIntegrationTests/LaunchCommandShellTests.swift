//
//  LaunchCommandShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `Profile.resolvedCommand` is actually safe once a
//  real shell parses it -- not just that `LaunchCommandPlanner`'s pure
//  functions look right in isolation. Runs the generated command line
//  through `/bin/sh -c`, exactly the context libghostty's `exec -l <line>`
//  puts it in, against a harmless argv/environment-dumping script.

import XCTest
@testable import Vakta

final class LaunchCommandShellTests: XCTestCase {
    private var tempDirectory: URL!
    private var dumperURL: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchCommandShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        outputDirectory = tempDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Writes argc/argv (one arg per line) and whether $SCRUBBED_VAR /
        // $KEPT_VAR are visible to the child, all into $OUT -- a stand-in
        // for the "harmless argument dumper" testing.md asks for.
        dumperURL = tempDirectory.appendingPathComponent("dump.sh")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$#" > "$OUT/argc"
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${SCRUBBED_VAR-<absent>}" > "$OUT/scrubbed_var"
        printf '%s\\n' "${KEPT_VAR-<absent>}" > "$OUT/kept_var"
        pwd > "$OUT/pwd"
        """
        try script.write(to: dumperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dumperURL.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Runs `resolvedCommand` through `/bin/sh -c`, the same shell-parsed
    /// context production uses.
    @discardableResult
    private func runResolvedCommand(
        _ command: String,
        extraEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = extraEnvironment
        environment["OUT"] = outputDirectory.path
        process.environment = environment
        process.currentDirectoryURL = currentDirectory ?? tempDirectory
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func readOutput(_ name: String) -> String? {
        try? String(contentsOf: outputDirectory.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: injection

    func test_maliciousSessionName_doesNotExecuteInjectedCommand() throws {
        let profile = Profile(name: "p", command: dumperURL.path, arguments: "--session {name}")
        let malicious = "x'; touch \(outputDirectory.path)/INJECTED; echo '"

        try runResolvedCommand(profile.resolvedCommand(sessionName: malicious))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("INJECTED").path),
            "the malicious session name must not have broken out of quoting to run an injected command"
        )
    }

    func test_maliciousSessionName_arrivesAsExactlyOneArgvEntry() throws {
        let profile = Profile(name: "p", command: dumperURL.path, arguments: "--session {name}")
        let malicious = "x'; touch pwned; echo '"

        try runResolvedCommand(profile.resolvedCommand(sessionName: malicious))

        XCTAssertEqual(readOutput("argc"), "2")
        let argv = (readOutput("argv") ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(argv, ["--session", malicious])
    }

    func test_dollarSubstitutionInSessionName_isNotExpanded() throws {
        let profile = Profile(name: "p", command: dumperURL.path, arguments: "--session {name}")
        let payload = "$(touch \(outputDirectory.path)/EXPANDED)"

        try runResolvedCommand(profile.resolvedCommand(sessionName: payload))

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("EXPANDED").path))
        let argv = (readOutput("argv") ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(argv, ["--session", payload])
    }

    func test_leadingDashSessionName_isPassedAsTheFlagsValue_notReinterpretedAsAFlag() throws {
        let profile = Profile(name: "p", command: dumperURL.path, arguments: "--session {name}")

        try runResolvedCommand(profile.resolvedCommand(sessionName: "-rf"))

        let argv = (readOutput("argv") ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(argv, ["--session", "-rf"])
    }

    func test_flagEqualsPlaceholder_arrivesAsOneCorrectArgument() throws {
        let profile = Profile(name: "p", command: dumperURL.path, arguments: "--session={name}")

        try runResolvedCommand(profile.resolvedCommand(sessionName: "has space"))

        let argv = (readOutput("argv") ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(argv, ["--session=has space"])
    }

    // MARK: scrub keys

    func test_scrubbedKey_isHiddenFromChild_unscrubbedKeyStaysVisible() throws {
        let profile = Profile(
            name: "p",
            command: dumperURL.path,
            scrubbedEnvironmentKeys: ["SCRUBBED_VAR"]
        )

        try runResolvedCommand(
            profile.resolvedCommand(sessionName: "irrelevant"),
            extraEnvironment: ["SCRUBBED_VAR": "secret", "KEPT_VAR": "visible"]
        )

        XCTAssertEqual(readOutput("scrubbed_var"), "<absent>")
        XCTAssertEqual(readOutput("kept_var"), "visible")
    }

    // `resolvedCommand` is a pure `String` function -- it has no way to
    // mutate Vakta's own process environment, so there's no meaningful test
    // for "it doesn't" (it can't fail). See the invariant documented on
    // `Profile.scrubbedEnvironmentKeys`: scrubbing happens via a shell `env
    // -u` prefix in the generated command specifically so nothing here ever
    // needs to touch `environ`.

func test_invalidScrubKey_isDroppedRatherThanInjectedIntoTheCommandLine() throws {
        let profile = Profile(
            name: "p",
            command: dumperURL.path,
            scrubbedEnvironmentKeys: ["KEPT_VAR; touch \(outputDirectory.path)/INJECTED"]
        )

        try runResolvedCommand(profile.resolvedCommand(sessionName: "irrelevant"), extraEnvironment: ["KEPT_VAR": "visible"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("INJECTED").path))
        XCTAssertEqual(readOutput("kept_var"), "visible", "an invalid scrub key must be dropped, not silently scrub something else")
    }

    // MARK: working directory

    func test_workingDirectory_isHonoredByTheSpawnedProcess() throws {
        let workDir = tempDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let profile = Profile(name: "p", command: dumperURL.path)

        try runResolvedCommand(profile.resolvedCommand(sessionName: "irrelevant"), currentDirectory: workDir)

        let resolvedWorkDir = try XCTUnwrap(URL(fileURLWithPath: workDir.path).resolvingSymlinksInPath().path as String?)
        let resolvedPWD = readOutput("pwd").map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(resolvedPWD, resolvedWorkDir)
    }
}
