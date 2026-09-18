//
//  ActivePaneWorkingDirectoryQueryTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the new multiplexer-backend capability #7
//  (docs/multiplexer-backends.md): the argv to find the currently focused
//  pane's working directory, and the pure parser turning its output into a
//  typed outcome. No process execution here -- see
//  `ActivePaneWorkingDirectoryShellTests` for that, including the
//  non-zero-exit case.
//
//  herdr fixture payloads are the real shape (`herdr --session <name> pane
//  current`, checked live against a running session -- see plan notes, not
//  vendored/documented in this repo elsewhere yet): a `result.pane` envelope
//  on success, an `error` envelope (with a `code`) on failure -- confirmed
//  live that herdr writes the error envelope to stdout even on a non-zero
//  exit code.
//
//  RED: `MultiplexerTarget.activePaneWorkingDirectoryArgv` and
//  `ActivePaneWorkingDirectoryQuery`/`ActivePaneWorkingDirectoryResult` do
//  not exist yet -- this file will not compile until they're declared.

import XCTest
@testable import Vakta

final class ActivePaneWorkingDirectoryQueryTests: XCTestCase {
    // MARK: argv

    func test_herdrArgv_targetsSessionsCurrentPane() {
        let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(
            target.activePaneWorkingDirectoryArgv(sessionName: "my-session"),
            ["herdr", "--session", "my-session", "pane", "current"]
        )
    }

    func test_tmuxArgv_queriesCurrentWindowsActivePanePath() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(
            target.activePaneWorkingDirectoryArgv(sessionName: "my-session"),
            ["tmux", "display-message", "-p", "-t", "my-session", "#{pane_current_path}"]
        )
    }

    func test_tmuxArgv_customSocket_isPassedAsAnArgument() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: "/tmp/custom.sock", environment: [:])
        XCTAssertEqual(
            target.activePaneWorkingDirectoryArgv(sessionName: "my-session"),
            ["tmux", "-S", "/tmp/custom.sock", "display-message", "-p", "-t", "my-session", "#{pane_current_path}"]
        )
    }

    // MARK: herdr parser

    func test_parseHerdr_validPayload_usesForegroundCwd() {
        // Verbatim `herdr --session default pane current` output, captured
        // against a live local session.
        let json = #"{"id":"cli:pane:current","result":{"pane":{"agent":"claude","agent_status":"working","cwd":"/Users/sam/src/vakta","focused":true,"foreground_cwd":"/Users/sam/src/vakta/subdir","pane_id":"w2H:p1","workspace_id":"w2H"}}}"#
        XCTAssertEqual(
            ActivePaneWorkingDirectoryQuery.parse(json, backend: .herdr),
            .workingDirectory("/Users/sam/src/vakta/subdir")
        )
    }

    func test_parseHerdr_missingForegroundCwd_fallsBackToCwd() {
        let json = #"{"result":{"pane":{"cwd":"/Users/sam/src/vakta","focused":true}}}"#
        XCTAssertEqual(
            ActivePaneWorkingDirectoryQuery.parse(json, backend: .herdr),
            .workingDirectory("/Users/sam/src/vakta")
        )
    }

    func test_parseHerdr_serverNotRunning_isTypedNotMalformed() {
        // Confirmed live: herdr writes this exact envelope to stdout with
        // exit code 1 when the session isn't running.
        let json = #"{"id":"cli:pane:current","error":{"code":"server_not_running","message":"no herdr server is running at ..."}}"#
        XCTAssertEqual(ActivePaneWorkingDirectoryQuery.parse(json, backend: .herdr), .serverNotRunning)
    }

    func test_parseHerdr_otherErrorCode_isTypedError() {
        let json = #"{"error":{"code":"no_current_pane","message":"nothing focused"}}"#
        XCTAssertEqual(ActivePaneWorkingDirectoryQuery.parse(json, backend: .herdr), .error(code: "no_current_pane"))
    }

    func test_parseHerdr_malformedJSON_isMalformed() {
        XCTAssertEqual(ActivePaneWorkingDirectoryQuery.parse("not json", backend: .herdr), .malformed)
    }

    func test_parseHerdr_emptyOutput_isMalformed() {
        XCTAssertEqual(ActivePaneWorkingDirectoryQuery.parse("", backend: .herdr), .malformed)
    }

    // MARK: tmux parser

    func test_parseTmux_singleLine_isWorkingDirectory() {
        XCTAssertEqual(
            ActivePaneWorkingDirectoryQuery.parse("/Users/sam/src/vakta\n", backend: .tmux),
            .workingDirectory("/Users/sam/src/vakta")
        )
    }

    func test_parseTmux_emptyOutput_isMalformed() {
        XCTAssertEqual(ActivePaneWorkingDirectoryQuery.parse("", backend: .tmux), .malformed)
    }

    func test_parseTmux_whitespaceOnlyOutput_isMalformed() {
        XCTAssertEqual(ActivePaneWorkingDirectoryQuery.parse("\n", backend: .tmux), .malformed)
    }
}
