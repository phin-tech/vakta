//
//  PaneFocusShellTests.swift
//  VaktaIntegrationTests
//
//  Shell regressions for selecting a pane from Cmd-K: Herdr receives an exact
//  pane.focus request, while tmux first selects the target window and then the
//  target pane.

import XCTest
@testable import Vakta

final class PaneFocusShellTests: XCTestCase {
    func test_herdrFocus_sendsExactPaneRequestToSessionSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/VaktaPaneFocus-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root
            .appendingPathComponent("sessions/demo", isDirectory: true)
            .appendingPathComponent("herdr.sock")
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try FixtureHerdrSocketServer(path: socketPath.path)
        defer { server.stop() }

        let received = expectation(description: "pane.focus request")
        server.onLineReceived = { index, line in
            guard line.contains("\"method\":\"pane.focus\""),
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requestID = request["id"] as? String
            else { return }
            received.fulfill()
            server.send(#"{"id":"\#(requestID)","result":{"type":"ok"}}"#, toConnectionAt: index)
        }

        let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
        let focusResult = PaneFocus.focus(
            sessionName: "demo",
            target: target,
            workspaceID: "w2C",
            paneID: "w2C:p7",
            path: "/usr/bin:/bin",
            configDirectory: root
        )
        XCTAssertTrue(focusResult)
        wait(for: [received], timeout: 2)

        let lines = server.requestLines(forConnectionAt: 0)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("\"pane_id\":\"w2C:p7\""))
    }

    func test_tmuxFocus_selectsTargetWindowAndPane() throws {
        guard let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw XCTSkip("tmux not found on this machine")
        }

        let socketName = "vakta-focus-\(UUID().uuidString.prefix(8))"
        let target = MultiplexerTarget(backend: .tmux, executable: tmuxPath, tmuxSocketName: socketName, environment: [:])
        func tmux(_ args: [String]) {
            _ = ProcessRunner.run([tmuxPath, "-L", socketName] + args, path: "/usr/bin:/bin")
        }
        func query(_ args: [String]) -> String? {
            ProcessRunner.run([tmuxPath, "-L", socketName] + args, path: "/usr/bin:/bin")
        }

        tmux(["new-session", "-d", "-s", "probe", "-n", "first"])
        tmux(["split-window", "-t", "probe:first"])
        tmux(["new-window", "-t", "probe", "-n", "second"])
        defer { tmux(["kill-server"]) }

        let panes = try XCTUnwrap(PaneQuery.panes(
            sessionName: "probe",
            target: target,
            workspaceID: "@0",
            path: "/usr/bin:/bin"
        ))
        let pane = try XCTUnwrap(panes.first)

        XCTAssertTrue(
            PaneFocus.focus(
                sessionName: "probe",
                target: target,
                workspaceID: "@0",
                paneID: pane.id,
                path: "/usr/bin:/bin"
            )
        )

        XCTAssertEqual(
            query(["display-message", "-p", "-t", "probe", "#{window_id}|#{pane_id}"])?.trimmingCharacters(in: .whitespacesAndNewlines),
            "@0|\(pane.id)"
        )
    }

    func test_tmuxFocusPaneDirection_movesToTheNeighbour() throws {
        guard let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw XCTSkip("tmux not found on this machine")
        }

        let socketName = "vakta-neighbour-\(UUID().uuidString.prefix(8))"
        let target = MultiplexerTarget(backend: .tmux, executable: tmuxPath, tmuxSocketName: socketName, environment: [:])
        func tmux(_ args: [String]) -> String? {
            ProcessRunner.run([tmuxPath, "-L", socketName] + args, path: "/usr/bin:/bin")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = tmux(["new-session", "-d", "-s", "probe", "-x", "200", "-y", "50", "sleep 60"])
        defer { _ = tmux(["kill-server"]) }
        let left = try XCTUnwrap(tmux(["display-message", "-p", "-t", "probe", "#{pane_id}"]))
        _ = tmux(["split-window", "-h", "-t", left, "sleep 60"])
        let right = try XCTUnwrap(tmux(["display-message", "-p", "-t", "probe", "#{pane_id}"]))
        XCTAssertNotEqual(left, right)
        _ = tmux(["select-pane", "-t", left])

        XCTAssertTrue(MultiplexerCommand.run(
            action: .focusPane(paneID: left, direction: .right),
            sessionName: "probe",
            target: target,
            path: "/usr/bin:/bin"
        ))
        XCTAssertEqual(tmux(["display-message", "-p", "-t", "probe", "#{pane_id}"]), right)

        XCTAssertTrue(MultiplexerCommand.run(
            action: .focusPane(paneID: right, direction: .left),
            sessionName: "probe",
            target: target,
            path: "/usr/bin:/bin"
        ))
        XCTAssertEqual(tmux(["display-message", "-p", "-t", "probe", "#{pane_id}"]), left)
    }
}
