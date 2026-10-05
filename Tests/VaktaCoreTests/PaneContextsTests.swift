//
//  PaneContextsTests.swift
//  VaktaCoreTests
//
//  Opt-in Pane Contexts: the manifest switch, building Pane Contexts from
//  a pane listing, stripping them for Extensions that didn't ask, and the
//  quick focused-first pass keeping the last known panes.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class PaneContextsTests: XCTestCase {
    func test_manifestContexts_optIn_andValidation() throws {
        let panes = try XCTUnwrap(ExtensionManifest.decode(Data(#"{"id":"x","name":"X","command":["./run"],"contexts":"panes"}"#.utf8)))
        XCTAssertTrue(panes.wantsPanes)
        XCTAssertEqual(panes.problems, [])
        XCTAssertFalse(try XCTUnwrap(ExtensionManifest.decode(Data(#"{"id":"x","name":"X","command":["./run"]}"#.utf8))).wantsPanes)
        let odd = try XCTUnwrap(ExtensionManifest.decode(Data(#"{"id":"x","name":"X","command":["./run"],"contexts":"windows"}"#.utf8)))
        XCTAssertEqual(odd.problems, [#"Contexts must be "sessions" or "panes"."#])
    }

    func test_paneContexts_fromListingAndCheckouts() {
        let panes = [
            Pane(id: "w2C:p1", tabID: "t1", label: "", focused: true, status: .none, workspaceID: "w2C", workingDirectory: "/repo/Sources"),
            Pane(id: "w2D:p1", tabID: "t2", label: "", focused: false, status: .none, workspaceID: "w2D", workingDirectory: "/tmp"),
            Pane(id: "w2D:p2", tabID: "t2", label: "", focused: false, status: .none, workspaceID: nil, workingDirectory: nil),
        ]
        let contexts = ExtensionContextPlanner.paneContexts(
            panes: panes,
            checkouts: ["/repo/Sources": RepoCheckout(root: "/repo", branch: "fix-login"), "/tmp": nil],
            workspaces: [Workspace(id: "w2C", label: "agents", focused: true)]
        )
        XCTAssertEqual(contexts, [
            PaneContext(paneID: "w2C:p1", workspace: WorkspaceRef(id: "w2C", label: "agents"), cwd: "/repo/Sources",
                        gitRoot: "/repo", branch: "fix-login", focused: true),
            PaneContext(paneID: "w2D:p1", workspace: WorkspaceRef(id: "w2D", label: "w2D"), cwd: "/tmp", gitRoot: nil, branch: nil, focused: false),
            PaneContext(paneID: "w2D:p2", workspace: nil, cwd: nil, gitRoot: nil, branch: nil, focused: false),
        ])
    }

    func test_stripping_removesPanesOnlyWhenNotWanted() {
        let context = ExtensionContext(
            sessionKey: SessionKey(backend: "herdr", sessionName: "v"), cwd: "/r", gitRoot: nil, branch: nil, workspace: nil,
            focused: true, panes: [PaneContext(paneID: "p", workspace: nil, cwd: "/r", gitRoot: nil, branch: nil, focused: true)]
        )
        XCTAssertNil(ExtensionContextPlanner.contexts([context], includingPanes: false).first?.panes)
        XCTAssertEqual(ExtensionContextPlanner.contexts([context], includingPanes: true), [context])
    }

    func test_focusedFirst_keepsTheLastKnownPanes_forTheFocusedSession() {
        let id = UUID()
        let input = ExtensionSessionInput(sessionID: id, target: nil, sessionName: "v", terminalReportedWorkingDirectory: nil,
                                          profileWorkingDirectory: nil, focusedWorkspace: nil, focused: true)
        let panes = [PaneContext(paneID: "p", workspace: nil, cwd: "/r", gitRoot: nil, branch: nil, focused: true)]
        let previous = ExtensionContext(sessionKey: SessionKey(backend: "shell", sessionName: "x"), cwd: "/old", gitRoot: nil,
                                        branch: nil, workspace: nil, focused: true, panes: panes)
        let fresh = ExtensionContext(sessionKey: SessionKey(backend: "shell", sessionName: "x"), cwd: "/new", gitRoot: nil,
                                     branch: nil, workspace: nil, focused: true)
        let merged = ExtensionContextPlanner.focusedFirst(inputs: [input], fresh: fresh, previous: [id: previous])
        XCTAssertEqual(merged.first?.cwd, "/new")
        XCTAssertEqual(merged.first?.panes, panes)
    }
}
