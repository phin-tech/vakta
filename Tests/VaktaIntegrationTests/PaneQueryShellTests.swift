//
//  PaneQueryShellTests.swift
//  VaktaIntegrationTests
//
//  Real-tmux regressions for pane discovery's working directories. Confirmed
//  live against tmux 3.7b: with `ProcessRunner`'s PATH/HOME-only environment
//  (no UTF-8 locale), tmux's `-F` engine rewrites non-ASCII bytes and control
//  separators to `_`, so a pane in `…/café` reported `…/caf_`. Fixture
//  scripts can't reach that class of bug, so these run an actual server on a
//  throwaway socket.

import XCTest
@testable import Vakta

final class PaneQueryShellTests: XCTestCase {
    private var tmuxPath: String!
    private var socketName: String!
    private var root: URL!

    override func setUpWithError() throws {
        guard let path = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw XCTSkip("tmux not found on this machine")
        }
        tmuxPath = path
        socketName = "vakta-panes-\(UUID().uuidString.prefix(8))"
        // tmux reports the physical path (`/private/var/…`); Foundation's
        // `resolvingSymlinksInPath()` strips `/private`, so resolve with
        // realpath(3) instead.
        let temporary = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporary, nil) else { throw XCTSkip("cannot resolve \(temporary)") }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("VaktaPaneQuery-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if tmuxPath != nil { tmux(["kill-server"]) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func tmux(_ args: [String]) {
        _ = ProcessRunner.run([tmuxPath, "-L", socketName] + args, path: "/usr/bin:/bin")
    }

    private func makeDirectory(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Panes run `sleep` rather than a login shell: a shell prompt rewrites
    /// the pane title asynchronously, racing `select-pane -T`.
    private let paneCommand = "sleep 60"

    private var target: MultiplexerTarget {
        MultiplexerTarget(backend: .tmux, executable: tmuxPath, tmuxSocketName: socketName, environment: [:])
    }

    func test_workspacePanes_reportExactWorkingDirectoryAndTitle_underMinimalEnvironment() throws {
        let directory = try makeDirectory("a|b café")
        tmux(["new-session", "-d", "-s", "probe", "-n", "first", "-c", directory, paneCommand])
        tmux(["select-pane", "-t", "probe:first", "-T", "editor|with pipe"])

        let panes = try XCTUnwrap(PaneQuery.panes(
            sessionName: "probe",
            target: target,
            workspaceID: "@0",
            path: "/usr/bin:/bin"
        ))

        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?.workingDirectory, directory)
        XCTAssertEqual(panes.first?.label, "editor|with pipe")
        XCTAssertEqual(panes.first?.workspaceID, "@0")
    }

    func test_sessionPanes_coverEveryWindowWithTheirWorkspaces() throws {
        let first = try makeDirectory("first")
        let second = try makeDirectory("second")
        tmux(["new-session", "-d", "-s", "probe", "-n", "first", "-c", first, paneCommand])
        tmux(["split-window", "-t", "probe:first", "-c", first, paneCommand])
        tmux(["new-window", "-t", "probe", "-n", "second", "-c", second, paneCommand])

        let panes = try XCTUnwrap(PaneQuery.panes(
            sessionName: "probe",
            target: target,
            path: "/usr/bin:/bin"
        ))

        XCTAssertEqual(panes.map(\.workingDirectory), [first, first, second])
        XCTAssertEqual(Set(panes.compactMap(\.workspaceID)).count, 2)
        // Session-wide, only the active window's active pane is focused --
        // matching herdr's one focused pane per session.
        XCTAssertEqual(panes.filter(\.focused).map(\.workingDirectory), [second])
    }
}
