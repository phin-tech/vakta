//
//  ExtensionContextPlannerTests.swift
//  VaktaCoreTests
//
//  Session Keys and the Extension Context built from one Session's
//  snapshot plus its query results.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class ExtensionContextPlannerTests: XCTestCase {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func input(
        terminal: String? = nil, profile: String? = nil, workspace: Workspace? = nil, focused: Bool = false
    ) -> ExtensionSessionInput {
        ExtensionSessionInput(
            sessionID: sessionID, target: nil, sessionName: "vakta",
            terminalReportedWorkingDirectory: terminal, profileWorkingDirectory: profile,
            focusedWorkspace: workspace, focused: focused
        )
    }

    func test_sessionKey_usesTheMultiplexerSessionName() {
        XCTAssertEqual(
            ExtensionContextPlanner.sessionKey(backend: .herdr, sessionName: "vakta", sessionID: sessionID),
            SessionKey(backend: "herdr", sessionName: "vakta")
        )
        XCTAssertEqual(
            ExtensionContextPlanner.sessionKey(backend: .tmux, sessionName: "work", sessionID: sessionID),
            SessionKey(backend: "tmux", sessionName: "work")
        )
    }

    func test_sessionKey_plainShell_fallsBackToTheSessionID() {
        XCTAssertEqual(
            ExtensionContextPlanner.sessionKey(backend: nil, sessionName: "zsh", sessionID: sessionID),
            SessionKey(backend: "shell", sessionName: "11111111-2222-3333-4444-555555555555")
        )
    }

    func test_context_prefersTheMultiplexerWorkingDirectory_andCarriesTheCheckout() {
        let context = ExtensionContextPlanner.context(
            for: input(terminal: "/osc7", profile: "/profile", workspace: Workspace(id: "w2C", label: "agents", focused: true), focused: true),
            multiplexerWorkingDirectory: .workingDirectory("/repo/Sources"),
            checkout: RepoCheckout(root: "/repo", branch: "3kav-extensions", config: [:])
        )
        XCTAssertEqual(context, ExtensionContext(
            sessionKey: SessionKey(backend: "shell", sessionName: sessionID.uuidString),
            cwd: "/repo/Sources", gitRoot: "/repo", branch: "3kav-extensions",
            workspace: WorkspaceRef(id: "w2C", label: "agents"), focused: true
        ))
    }

    func test_context_fallsBackToTerminalThenProfileDirectory_andOmitsAMissingCheckout() {
        let fromTerminal = ExtensionContextPlanner.context(
            for: input(terminal: "/osc7", profile: "/profile"), multiplexerWorkingDirectory: .serverNotRunning, checkout: nil
        )
        XCTAssertEqual(fromTerminal.cwd, "/osc7")
        XCTAssertNil(fromTerminal.gitRoot)
        XCTAssertNil(fromTerminal.branch)
        XCTAssertNil(fromTerminal.workspace)
        XCTAssertFalse(fromTerminal.focused)

        let fromProfile = ExtensionContextPlanner.context(
            for: input(profile: "/profile"), multiplexerWorkingDirectory: nil, checkout: nil
        )
        XCTAssertEqual(fromProfile.cwd, "/profile")
    }

    func test_context_detachedHead_hasRootButNoBranch() {
        let context = ExtensionContextPlanner.context(
            for: input(terminal: "/repo"), multiplexerWorkingDirectory: nil,
            checkout: RepoCheckout(root: "/repo", branch: nil, config: [:])
        )
        XCTAssertEqual(context.gitRoot, "/repo")
        XCTAssertNil(context.branch)
    }

    func test_focusedFirst_usesTheFreshFocusedContext_andLastKnownOthers_inOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        func input(_ id: UUID, _ name: String, focused: Bool) -> ExtensionSessionInput {
            ExtensionSessionInput(sessionID: id, target: nil, sessionName: name, terminalReportedWorkingDirectory: nil,
                                  profileWorkingDirectory: nil, focusedWorkspace: nil, focused: focused)
        }
        func context(_ id: UUID, cwd: String, focused: Bool) -> ExtensionContext {
            ExtensionContext(sessionKey: SessionKey(backend: "shell", sessionName: id.uuidString), cwd: cwd, gitRoot: nil,
                             branch: nil, workspace: nil, focused: focused)
        }
        let previous = [a: context(a, cwd: "/old-a", focused: true), b: context(b, cwd: "/b", focused: false)]
        let fresh = context(b, cwd: "/new-b", focused: true)

        let merged = ExtensionContextPlanner.focusedFirst(
            inputs: [input(a, "a", focused: false), input(b, "b", focused: true), input(c, "c", focused: false)],
            fresh: fresh, previous: previous
        )

        XCTAssertEqual(merged, [context(a, cwd: "/old-a", focused: false), fresh], "c was never gathered, so it waits for the full pass")
    }
}
