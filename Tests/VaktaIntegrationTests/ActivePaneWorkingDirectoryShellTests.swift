//
//  ActivePaneWorkingDirectoryShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `ActivePaneWorkingDirectoryQuery.query` actually
//  threads a `MultiplexerTarget`'s executable/environment through to a real
//  child process, per testing.md's strategy -- mirrors
//  `LaunchTargetShellTests`. Critically also proves the query reads stdout
//  on a NON-ZERO exit: `ProcessRunner.run` (used by `WorkspaceQuery`/
//  `HerdrAgentStatus`) discards stdout whenever the child exits non-zero
//  (confirmed by reading `ProcessRunner.swift`), but herdr writes its error
//  envelope to stdout WITH exit code 1 (confirmed live against a real
//  session: `server_not_running`). A query built on `ProcessRunner` would
//  silently collapse every herdr error into `.malformed`, discarding the
//  actual error code -- this regression test is what would have caught
//  that.
//
//  RED: `ActivePaneWorkingDirectoryQuery.query` does not exist yet -- this
//  file will not compile until it's declared.

import XCTest
@testable import Vakta

final class ActivePaneWorkingDirectoryShellTests: XCTestCase {
    private var tempDirectory: URL!
    private var captureURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivePaneWorkingDirectoryShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        captureURL = tempDirectory.appendingPathComponent("capture.sh")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func writeScript(_ body: String) throws {
        try body.write(to: captureURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)
    }

    func test_query_herdrSuccess_usesTargetsExecutableAndEnvironment() throws {
        try writeScript("""
        #!/bin/sh
        printf '{"result":{"pane":{"cwd":"/tmp","foreground_cwd":"/tmp/sub","focused":true}}}'
        """)

        let target = MultiplexerTarget(backend: .herdr, executable: captureURL.path, tmuxSocketPath: nil, environment: [:])

        let result = ActivePaneWorkingDirectoryQuery.query(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertEqual(result, .workingDirectory("/tmp/sub"))
    }

    func test_query_herdrNonZeroExit_stillReadsTheErrorEnvelopeFromStdout() throws {
        // Reproduces the live, confirmed shape: herdr exits 1 and writes its
        // error envelope to stdout, not stderr.
        try writeScript("""
        #!/bin/sh
        printf '{"id":"cli:pane:current","error":{"code":"server_not_running","message":"no herdr server is running"}}'
        exit 1
        """)

        let target = MultiplexerTarget(backend: .herdr, executable: captureURL.path, tmuxSocketPath: nil, environment: [:])

        let result = ActivePaneWorkingDirectoryQuery.query(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertEqual(result, .serverNotRunning)
    }

    func test_query_launchFailure_isMalformedNotACrash() {
        let target = MultiplexerTarget(
            backend: .herdr,
            executable: tempDirectory.appendingPathComponent("does-not-exist").path,
            tmuxSocketPath: nil,
            environment: [:]
        )

        let result = ActivePaneWorkingDirectoryQuery.query(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertEqual(result, .malformed)
    }

    func test_query_tmux_usesTargetsExecutableAndEnvironment() throws {
        try writeScript("""
        #!/bin/sh
        printf '/Users/sam/src/vakta\\n'
        """)

        let target = MultiplexerTarget(backend: .tmux, executable: captureURL.path, tmuxSocketPath: nil, environment: [:])

        let result = ActivePaneWorkingDirectoryQuery.query(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertEqual(result, .workingDirectory("/Users/sam/src/vakta"))
    }
}
