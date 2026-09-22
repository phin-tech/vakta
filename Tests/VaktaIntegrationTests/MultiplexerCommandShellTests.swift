//
//  MultiplexerCommandShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `MultiplexerCommand.run` actually threads a
//  `MultiplexerTarget`'s executable/environment/socket through to a real
//  child process for a mutating action -- not just that `actionArgv` looks
//  right in isolation (see `MultiplexerActionTests`). Uses a temporary helper
//  executable that captures its argv/environment, mirroring
//  `LaunchTargetShellTests`/`WorkspaceFocus`.

import XCTest
@testable import Vakta

final class MultiplexerCommandShellTests: XCTestCase {
    private var tempDirectory: URL!
    private var outputDirectory: URL!
    private var captureURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiplexerCommandShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        outputDirectory = tempDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        captureURL = tempDirectory.appendingPathComponent("capture.sh")
        try writeCapture(stdout: "{\"result\":{}}", exit: 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func writeCapture(stdout: String, exit code: Int) throws {
        let script = """
        #!/bin/sh
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${MARKER-<absent>}" > "$OUT/marker"
        printf '%s' '\(stdout)'
        exit \(code)
        """
        try script.write(to: captureURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)
    }

    private func readOutput(_ name: String) -> String? {
        try? String(contentsOf: outputDirectory.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test_herdrSplit_threadsExecutableEnvironmentAndArgv_andReportsSuccess() {
        let target = MultiplexerTarget(
            backend: .herdr,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["MARKER": "from-profile", "OUT": outputDirectory.path]
        )

        let succeeded = MultiplexerCommand.run(
            action: .splitPane(paneID: "w2C:p3", direction: .right),
            sessionName: "my-session",
            target: target,
            path: "/usr/bin:/bin"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            readOutput("argv"),
            "--session\nmy-session\npane\nsplit\n--pane\nw2C:p3\n--direction\nright\n--focus"
        )
        XCTAssertEqual(readOutput("marker"), "from-profile")
    }

    func test_tmuxCloseWorkspace_threadsCustomSocketAndArgv() {
        let target = MultiplexerTarget(
            backend: .tmux,
            executable: captureURL.path,
            tmuxSocketPath: "/tmp/custom.sock",
            environment: ["OUT": outputDirectory.path]
        )

        let succeeded = MultiplexerCommand.run(
            action: .closeWorkspace(workspaceID: "@1"),
            sessionName: "my-session",
            target: target,
            path: "/usr/bin:/bin"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(readOutput("argv"), "-S\n/tmp/custom.sock\nkill-window\n-t\nmy-session:@1")
    }

    func test_nonZeroExit_reportsFailure() throws {
        try writeCapture(stdout: "", exit: 1)

        let target = MultiplexerTarget(
            backend: .herdr,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["OUT": outputDirectory.path]
        )

        let succeeded = MultiplexerCommand.run(
            action: .closePane(paneID: "w2C:p3"),
            sessionName: "my-session",
            target: target,
            path: "/usr/bin:/bin"
        )

        XCTAssertFalse(succeeded)
    }
}
