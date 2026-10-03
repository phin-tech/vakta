//
//  ExtensionLaunchPlannerTests.swift
//  VaktaCoreTests
//
//  open_pane / open_session plans: argv stays argv per backend, herdr's
//  split output yields the new pane id, and a new Session's profile quotes
//  every word.

import XCTest
@testable import Vakta

final class ExtensionLaunchPlannerTests: XCTestCase {
    private func target(_ backend: MultiplexerTarget.Backend, executable: String) -> MultiplexerTarget {
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(
            Profile(name: "x", command: executable, arguments: backend == .herdr ? "--session {name}" : "new -A -s {name}")
        ) else { fatalError("not a multiplexer profile") }
        return target
    }

    func test_tmux_splitsAndRunsTheArgvDirectly_inTheCwd() {
        let plan = ExtensionLaunchPlanner.panePlan(
            target: target(.tmux, executable: "tmux"), sessionName: "work", cwd: "/repo",
            command: ["claude", "work on fcae; rm -rf /"]
        )
        XCTAssertEqual(plan, .single(["tmux", "split-window", "-h", "-t", "work", "-c", "/repo", "--", "claude", "work on fcae; rm -rf /"]))
    }

    func test_tmux_withoutCwd_omitsTheFlag() {
        XCTAssertEqual(
            ExtensionLaunchPlanner.panePlan(target: target(.tmux, executable: "tmux"), sessionName: "work", cwd: nil, command: ["htop"]),
            .single(["tmux", "split-window", "-h", "-t", "work", "--", "htop"])
        )
    }

    func test_herdr_splitsTheCurrentPane_thenRunsInTheNewOne() {
        XCTAssertEqual(
            ExtensionLaunchPlanner.panePlan(target: target(.herdr, executable: "herdr"), sessionName: "vakta", cwd: "/repo", command: ["claude", "go"]),
            .splitThenRun(
                split: ["herdr", "--session", "vakta", "pane", "split", "--current", "--direction", "right", "--cwd", "/repo", "--focus"],
                runPrefix: ["herdr", "--session", "vakta", "pane", "run"],
                command: ["claude", "go"]
            )
        )
    }

    func test_emptyCommand_hasNoPlan() {
        XCTAssertNil(ExtensionLaunchPlanner.panePlan(target: target(.tmux, executable: "tmux"), sessionName: "w", cwd: nil, command: []))
    }

    func test_herdrSplitPaneID() {
        let output = #"{"id":"cli","result":{"type":"pane_info","pane":{"pane_id":"w2C:p4","focused":true,"cwd":"/repo"}}}"#
        XCTAssertEqual(ExtensionLaunchPlanner.herdrSplitPaneID(output), "w2C:p4")
        XCTAssertEqual(ExtensionLaunchPlanner.herdrSplitPaneID(output + "\n"), "w2C:p4")
        XCTAssertNil(ExtensionLaunchPlanner.herdrSplitPaneID(#"{"error":{"code":"server_not_running"}}"#))
        XCTAssertNil(ExtensionLaunchPlanner.herdrSplitPaneID("garbage"))
    }

    func test_sessionProfile_quotesEveryWord() throws {
        let profile = try ExtensionLaunchPlanner.sessionProfile(cwd: "/repo", command: ["kata", "tui", "$(whoami)", "it's"], title: "Kata").get()
        XCTAssertEqual(profile.name, "Kata")
        XCTAssertEqual(profile.workingDirectory, "/repo")
        XCTAssertEqual(profile.resolvedCommand(sessionName: "ignored"), #"'kata' 'tui' '$(whoami)' 'it'\''s'"#)
    }

    func test_sessionProfile_defaultsTheNameToTheProgram_andRejectsBadInput() throws {
        XCTAssertEqual(try ExtensionLaunchPlanner.sessionProfile(cwd: nil, command: ["htop"], title: nil).get().name, "htop")
        XCTAssertThrowsError(try ExtensionLaunchPlanner.sessionProfile(cwd: nil, command: [], title: nil).get())
        XCTAssertThrowsError(
            try ExtensionLaunchPlanner.sessionProfile(cwd: nil, command: ["echo", "{name}"], title: nil).get(),
            "the profile template's {name} placeholder can't come from extension data"
        )
    }
}
