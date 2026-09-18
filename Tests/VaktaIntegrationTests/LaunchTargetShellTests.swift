//
//  LaunchTargetShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `ProcessRunner`/`SessionDiscovery`/`HerdrAgentStatus`
//  actually thread a `MultiplexerTarget`'s executable/environment/socket
//  through to a real child process -- not just that the pure argv-building
//  functions look right in isolation (see `LaunchTargetTests`). Uses a real
//  temporary helper executable that captures its argv/environment, per
//  testing.md's strategy for this issue.

import XCTest
@testable import Vakta

final class LaunchTargetShellTests: XCTestCase {
    private var tempDirectory: URL!
    private var outputDirectory: URL!
    private var captureURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchTargetShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        outputDirectory = tempDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // A stand-in "herdr"/"tmux" binary: writes its own argv and a marker
        // environment variable to $OUT, then prints a fixed session list to
        // stdout so the real parsers have something to chew on.
        captureURL = tempDirectory.appendingPathComponent("capture.sh")
        let script = """
        #!/bin/sh
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${MARKER-<absent>}" > "$OUT/marker"
        printf 'name\\trunning\\ndefault\\ttrue\\nother\\ttrue\\n'
        """
        try script.write(to: captureURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func readOutput(_ name: String) -> String? {
        try? String(contentsOf: outputDirectory.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: ProcessRunner

    func test_processRunner_environmentOverride_reachesTheChild() {
        _ = ProcessRunner.run(
            [captureURL.path],
            path: "/usr/bin:/bin",
            environment: ["MARKER": "hello", "OUT": outputDirectory.path]
        )
        XCTAssertEqual(readOutput("marker"), "hello")
    }

    func test_processRunner_noOverride_marksAbsent() {
        _ = ProcessRunner.run([captureURL.path], path: "/usr/bin:/bin", environment: ["OUT": outputDirectory.path])
        XCTAssertEqual(readOutput("marker"), "<absent>")
    }

    // MARK: SessionDiscovery

    func test_sessionDiscovery_usesTargetsExecutableAndEnvironment_notAHardcodedBinaryName() {
        let target = MultiplexerTarget(
            backend: .herdr,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["MARKER": "from-profile", "OUT": outputDirectory.path]
        )

        let names = SessionDiscovery.names(for: target, path: "/usr/bin:/bin")

        XCTAssertEqual(names, ["default", "other"])
        XCTAssertEqual(readOutput("argv"), "session\nlist")
        XCTAssertEqual(readOutput("marker"), "from-profile")
    }

    func test_sessionDiscovery_tmuxCustomSocket_isPassedAsAnArgument() {
        let target = MultiplexerTarget(
            backend: .tmux,
            executable: captureURL.path,
            tmuxSocketPath: "/tmp/custom.sock",
            environment: ["OUT": outputDirectory.path]
        )

        _ = SessionDiscovery.names(for: target, path: "/usr/bin:/bin")

        XCTAssertEqual(readOutput("argv"), "-S\n/tmp/custom.sock\nlist-sessions\n-F\n#{session_name}")
    }

    // MARK: HerdrAgentStatus

    func test_herdrAgentStatus_usesTargetsExecutableAndEnvironment() {
        // Override the fixture with one that emits a minimal valid `agent
        // list` JSON payload instead of the table format.
        let script = """
        #!/bin/sh
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${MARKER-<absent>}" > "$OUT/marker"
        printf '{"result":{"agents":[{"agent_status":"working"}]}}'
        """
        try? script.write(to: captureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)

        let target = MultiplexerTarget(
            backend: .herdr,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["MARKER": "status-poll", "OUT": outputDirectory.path]
        )

        let status = HerdrAgentStatus.status(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertEqual(status, .working)
        XCTAssertEqual(readOutput("argv"), "--session\nmy-session\nagent\nlist")
        XCTAssertEqual(readOutput("marker"), "status-poll")
    }

    func test_herdrAgentStatus_tmuxTarget_returnsNilWithoutRunningAnything() {
        let target = MultiplexerTarget(
            backend: .tmux,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["OUT": outputDirectory.path]
        )

        let status = HerdrAgentStatus.status(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertNil(status)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("argv").path))
    }

    // MARK: TmuxCommandStatusRecorder

    func test_tmuxCommandStatusRecorder_queriesCurrentWindowAndPersistsExitCode() {
        let script = """
        #!/bin/sh
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        if [ "$1" = "display-message" ]; then
            printf '@1\\n'
        fi
        """
        try? script.write(to: captureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)

        let target = MultiplexerTarget(
            backend: .tmux,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["OUT": outputDirectory.path]
        )

        XCTAssertTrue(
            TmuxCommandStatusRecorder.record(
                exitCode: 7,
                sessionName: "my-session",
                target: target,
                path: "/usr/bin:/bin"
            )
        )
        XCTAssertEqual(
            readOutput("argv"),
            "display-message\n-p\n-t\nmy-session\n#{window_id}\nset-window-option\n-t\nmy-session:@1\n@vakta_last_exit\n7"
        )
    }

    // MARK: WorkspaceQuery

    func test_workspaceQuery_usesTargetsExecutableAndEnvironment() {
        let script = """
        #!/bin/sh
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${MARKER-<absent>}" > "$OUT/marker"
        printf '{"result":{"workspaces":[{"workspace_id":"w2C","label":"guildhall","focused":true,"agent_status":"idle","number":1,"tab_count":1,"pane_count":2,"active_tab_id":"w2C:t1"}]}}'
        """
        try? script.write(to: captureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)

        let target = MultiplexerTarget(
            backend: .herdr,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["MARKER": "workspace-poll", "OUT": outputDirectory.path]
        )

        let workspaces = WorkspaceQuery.workspaces(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertEqual(workspaces, [Workspace(id: "w2C", label: "guildhall", focused: true)])
        XCTAssertEqual(readOutput("argv"), "--session\nmy-session\nworkspace\nlist")
        XCTAssertEqual(readOutput("marker"), "workspace-poll")
    }

    func test_workspaceQuery_tmuxTarget_listsWindows_usingTargetsExecutableAndEnvironment() {
        let script = """
        #!/bin/sh
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${MARKER-<absent>}" > "$OUT/marker"
        printf '@1|guildhall|1|0\\n@2|vakta|0|3\\n'
        """
        try? script.write(to: captureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)

        let target = MultiplexerTarget(
            backend: .tmux,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["MARKER": "workspace-poll", "OUT": outputDirectory.path]
        )

        let workspaces = WorkspaceQuery.workspaces(sessionName: "my-session", target: target, path: "/usr/bin:/bin")

        XCTAssertEqual(
            workspaces,
            [
                Workspace(id: "@1", label: "guildhall", focused: true, lastCommandExitCode: 0),
                Workspace(id: "@2", label: "vakta", focused: false, lastCommandExitCode: 3),
            ]
        )
        XCTAssertEqual(
            readOutput("argv"),
            "list-windows\n-t\nmy-session\n-F\n#{window_id}|#{window_name}|#{window_active}|#{@vakta_last_exit}"
        )
        XCTAssertEqual(readOutput("marker"), "workspace-poll")
    }

    func test_workspaceQuery_realTmuxServer_windowNamesSurviveTheDefaultProcessEnvironment() throws {
        // Regression test for a real bug: `ProcessRunner.run` deliberately
        // sets only `PATH`/`HOME` (see its doc comment) -- no `LANG`/
        // `LC_ALL`. Confirmed live against tmux 3.7b: without a UTF-8 locale
        // in the environment, tmux's `-F` format engine silently substitutes
        // "unprintable" bytes (including a tab delimiter) with `_`, which
        // would corrupt a tab-separated format and previously produced zero
        // parsed workspaces from a real 3-window session despite the raw
        // command succeeding when run interactively. `workspaceListArgv`
        // uses `|`, a plain printable delimiter, specifically to survive
        // this. The fixture-script test above can't catch this class of bug
        // (it doesn't invoke real tmux), so this one runs an actual tmux
        // server on a throwaway socket.
        guard let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw XCTSkip("tmux not found on this machine")
        }

        let socketName = "vakta-test-\(UUID().uuidString.prefix(8))"
        func tmux(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tmuxPath)
            p.arguments = ["-L", socketName] + args
            try? p.run()
            p.waitUntilExit()
        }
        tmux(["new-session", "-d", "-s", "probe", "-n", "editor"])
        tmux(["new-window", "-t", "probe", "-n", "build"])
        defer { tmux(["kill-server"]) }

        let target = MultiplexerTarget(backend: .tmux, executable: tmuxPath, tmuxSocketName: socketName, environment: [:])

        let workspaces = try XCTUnwrap(WorkspaceQuery.workspaces(sessionName: "probe", target: target, path: "/usr/bin:/bin"))

        XCTAssertEqual(workspaces.map(\.label), ["editor", "build"])
        XCTAssertEqual(workspaces.map(\.focused), [false, true])
        XCTAssertTrue(workspaces.allSatisfy { $0.id.hasPrefix("@") })
    }

    // MARK: WorkspaceFocus

    func test_workspaceFocus_usesTargetsExecutableAndEnvironment_andReportsSuccess() {
        let script = """
        #!/bin/sh
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${MARKER-<absent>}" > "$OUT/marker"
        printf '{"result":{}}'
        """
        try? script.write(to: captureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)

        let target = MultiplexerTarget(
            backend: .herdr,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["MARKER": "workspace-focus", "OUT": outputDirectory.path]
        )

        let succeeded = WorkspaceFocus.focus(
            sessionName: "my-session",
            target: target,
            workspaceID: "ws-1",
            path: "/usr/bin:/bin"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(readOutput("argv"), "--session\nmy-session\nworkspace\nfocus\nws-1")
        XCTAssertEqual(readOutput("marker"), "workspace-focus")
    }

    func test_workspaceFocus_nonZeroExit_reportsFailure() {
        let script = """
        #!/bin/sh
        exit 1
        """
        try? script.write(to: captureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)

        let target = MultiplexerTarget(
            backend: .herdr,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["OUT": outputDirectory.path]
        )

        let succeeded = WorkspaceFocus.focus(
            sessionName: "my-session",
            target: target,
            workspaceID: "ws-1",
            path: "/usr/bin:/bin"
        )

        XCTAssertFalse(succeeded)
    }

    func test_workspaceFocus_tmuxTarget_selectsWindow_usingTargetsExecutableAndEnvironment() {
        let script = """
        #!/bin/sh
        : > "$OUT/argv"
        for a in "$@"; do
            printf '%s\\n' "$a" >> "$OUT/argv"
        done
        printf '%s\\n' "${MARKER-<absent>}" > "$OUT/marker"
        """
        try? script.write(to: captureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureURL.path)

        let target = MultiplexerTarget(
            backend: .tmux,
            executable: captureURL.path,
            tmuxSocketPath: nil,
            environment: ["MARKER": "workspace-focus", "OUT": outputDirectory.path]
        )

        let succeeded = WorkspaceFocus.focus(
            sessionName: "my-session",
            target: target,
            workspaceID: "@1",
            path: "/usr/bin:/bin"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(readOutput("argv"), "select-window\n-t\nmy-session:@1")
        XCTAssertEqual(readOutput("marker"), "workspace-focus")
    }
}
