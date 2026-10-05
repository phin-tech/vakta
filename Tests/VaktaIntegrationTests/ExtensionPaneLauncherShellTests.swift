//
//  ExtensionPaneLauncherShellTests.swift
//  VaktaIntegrationTests
//
//  open_pane against a real tmux server on a private socket (never the
//  user's): the command runs in a new pane, in the requested directory,
//  with its arguments passed through untouched.

import XCTest
@testable import Vakta

final class ExtensionPaneLauncherShellTests: XCTestCase {
    private var socket: String!
    private var directory: URL!
    private let environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()]

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tmux")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/tmux")
        else { throw XCTSkip("tmux isn't installed") }
        socket = "vakta-ext-test-\(UUID().uuidString.prefix(8))"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionPaneLauncherShellTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = BoundedProcessRunner.run(
            executable: "/usr/bin/env", arguments: ["tmux", "-L", socket, "new-session", "-d", "-s", "work", "-x", "160", "-y", "40"],
            environment: environment, timeout: 10
        )
        guard case .success = started else { throw XCTSkip("couldn't start a private tmux server: \(started)") }
    }

    override func tearDownWithError() throws {
        if let socket {
            _ = BoundedProcessRunner.run(executable: "/usr/bin/env", arguments: ["tmux", "-L", socket, "kill-server"], environment: environment, timeout: 5)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func target() throws -> MultiplexerTarget {
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(
            Profile(name: "t", command: "tmux", arguments: "-L \(socket!) new -A -s {name}")
        ) else { throw XCTSkip("profile didn't resolve to tmux") }
        return target
    }

    private func paneCount() -> Int {
        guard case .success(let output) = BoundedProcessRunner.run(
            executable: "/usr/bin/env", arguments: ["tmux", "-L", socket, "list-panes", "-t", "work"], environment: environment, timeout: 5
        ) else { return -1 }
        return output.split(separator: "\n").count
    }

    func test_openPane_runsTheCommandInANewPane_inTheDirectory_withArgumentsIntact() throws {
        let plan = try XCTUnwrap(ExtensionLaunchPlanner.panePlan(
            target: try target(), sessionName: "work", cwd: directory.path,
            // Stays alive afterwards: tmux closes a pane whose command exits.
            command: ["/bin/sh", "-c", "pwd > out.txt; printf '%s' \"$0\" > arg.txt; sleep 30", "it's; $(not run)"]
        ))

        XCTAssertNil(ExtensionPaneLauncher.launch(plan, environment: environment))

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("arg.txt").path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("out.txt")).trimmingCharacters(in: .newlines), directory.path)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("arg.txt")), "it's; $(not run)")
        XCTAssertEqual(paneCount(), 2)
    }

    func test_gatherWithPanes_listsEveryPane_withItsCheckout() throws {
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = BoundedProcessRunner.run(executable: "/usr/bin/env", arguments: ["git", "-C", repo.path, "init", "-q", "-b", "fix-login"],
                                     environment: environment, timeout: 10)
        _ = BoundedProcessRunner.run(executable: "/usr/bin/env",
                                     arguments: ["tmux", "-L", socket, "split-window", "-t", "work", "-c", repo.path, "sleep 30"],
                                     environment: environment, timeout: 5)
        let input = ExtensionSessionInput(sessionID: UUID(), target: try target(), sessionName: "work",
                                          terminalReportedWorkingDirectory: nil, profileWorkingDirectory: nil,
                                          focusedWorkspace: nil, focused: true)

        let contexts = ExtensionContextGatherer.gather([input], path: environment["PATH"]!, includingPanes: true)

        let panes = try XCTUnwrap(contexts.first?.panes)
        XCTAssertEqual(panes.count, 2)
        let repoPane = try XCTUnwrap(panes.first { $0.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == repo.path })
        XCTAssertEqual(repoPane.branch, "fix-login")
        XCTAssertNotNil(repoPane.workspace)
        XCTAssertNil(ExtensionContextGatherer.gather([input], path: environment["PATH"]!).first?.panes, "not listed unless asked")
    }

    func test_openPane_inAMissingSession_reportsWhy() throws {
        let plan = try XCTUnwrap(ExtensionLaunchPlanner.panePlan(target: try target(), sessionName: "nope", cwd: nil, command: ["true"]))
        XCTAssertNotNil(ExtensionPaneLauncher.launch(plan, environment: environment))
    }
}
