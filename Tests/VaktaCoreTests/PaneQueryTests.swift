//
//  PaneQueryTests.swift
//  VaktaCoreTests
//
//  RED tests for the pane level of the Cmd-K hierarchy. Pane discovery must
//  include ordinary shell panes, not only panes with recognized agents.

import XCTest
@testable import Vakta

final class PaneQueryTests: XCTestCase {
    func test_parse_herdrPaneList_decodesAgentAndPlainShellPanes() {
        let json = #"{"result":{"panes":[{"agent":"claude","agent_status":"idle","cwd":"/repo","focused":true,"pane_id":"w2G:p1","tab_id":"w2G:t1","terminal_title_stripped":"claude","workspace_id":"w2G"},{"agent_status":"unknown","cwd":"/repo","focused":false,"pane_id":"w2G:pB","tab_id":"w2G:t5","terminal_title_stripped":"shell","workspace_id":"w2G"}]}}"#

        XCTAssertEqual(
            PaneQuery.parse(json, backend: .herdr),
            [
                Pane(id: "w2G:p1", tabID: "w2G:t1", label: "claude", focused: true, status: .idle, workspaceID: "w2G", workingDirectory: "/repo"),
                Pane(id: "w2G:pB", tabID: "w2G:t5", label: "shell", focused: false, status: .none, workspaceID: "w2G", workingDirectory: "/repo")
            ]
        )
    }

    func test_parse_herdrPaneList_prefersPaneLabelOverTerminalTitle() {
        let json = #"{"result":{"panes":[{"agent_status":"unknown","focused":true,"label":"test-123","pane_id":"w2C:p4","tab_id":"w2C:t1","terminal_title_stripped":"~/s/g/a/guildhall"}]}}"#

        XCTAssertEqual(
            PaneQuery.parse(json, backend: .herdr),
            [Pane(id: "w2C:p4", tabID: "w2C:t1", label: "test-123", focused: true, status: .none)]
        )
    }

    func test_parse_herdrPaneList_emptyPaneLabel_fallsBackToTerminalTitle() {
        let json = #"{"result":{"panes":[{"focused":false,"label":"","pane_id":"w2C:p4","terminal_title_stripped":"shell"}]}}"#

        XCTAssertEqual(
            PaneQuery.parse(json, backend: .herdr),
            [Pane(id: "w2C:p4", tabID: "", label: "shell", focused: false, status: .none)]
        )
    }

    func test_parse_herdrErrorPayload_isNil() {
        let json = #"{"error":{"code":"server_not_running","message":"no server"}}"#
        XCTAssertNil(PaneQuery.parse(json, backend: .herdr))
    }

    func test_parse_herdrMalformedJSON_isNil() {
        XCTAssertNil(PaneQuery.parse("not json", backend: .herdr))
    }

    func test_parse_herdrMissingOptionalFields_usesSafeFallbacks() {
        let json = #"{"result":{"panes":[{"pane_id":"w2G:p1","terminal_title_stripped":"shell"}]}}"#

        XCTAssertEqual(
            PaneQuery.parse(json, backend: .herdr),
            [Pane(id: "w2G:p1", tabID: "", label: "shell", focused: false, status: .none)]
        )
    }

    // MARK: herdr working directory

    func test_parse_herdrPaneList_foregroundCwdWinsOverShellCwd() {
        let json = #"{"result":{"panes":[{"cwd":"/repo","foreground_cwd":"/repo/sub","pane_id":"w2C:p1","workspace_id":"w2C","terminal_title_stripped":"vim"}]}}"#

        XCTAssertEqual(PaneQuery.parse(json, backend: .herdr)?.first?.workingDirectory, "/repo/sub")
    }

    func test_parse_herdrPaneList_shellCwdUsedWithoutForegroundCwd() {
        let json = #"{"result":{"panes":[{"cwd":"/repo","pane_id":"w2C:p1","terminal_title_stripped":"shell"}]}}"#

        XCTAssertEqual(PaneQuery.parse(json, backend: .herdr)?.first?.workingDirectory, "/repo")
    }

    func test_parse_herdrPaneList_emptyForegroundCwd_fallsBackToShellCwd() {
        let json = #"{"result":{"panes":[{"cwd":"/repo","foreground_cwd":"","pane_id":"w2C:p1","terminal_title_stripped":"shell"}]}}"#

        XCTAssertEqual(PaneQuery.parse(json, backend: .herdr)?.first?.workingDirectory, "/repo")
    }

    func test_parse_herdrPaneList_noUsableCwd_isNil() {
        let json = #"{"result":{"panes":[{"cwd":"","pane_id":"w2C:p1","terminal_title_stripped":"shell"},{"pane_id":"w2C:p2","terminal_title_stripped":"shell"}]}}"#

        XCTAssertEqual(PaneQuery.parse(json, backend: .herdr)?.map(\.workingDirectory), [nil, nil])
    }

    func test_parse_herdrSessionWidePaneList_keepsEachPanesWorkspace() {
        let json = #"{"result":{"panes":[{"pane_id":"w2C:p1","workspace_id":"w2C","terminal_title_stripped":"a"},{"pane_id":"w3A:p1","workspace_id":"w3A","terminal_title_stripped":"b"}]}}"#

        XCTAssertEqual(PaneQuery.parse(json, backend: .herdr)?.map(\.workspaceID), ["w2C", "w3A"])
    }

    // MARK: tmux
    //
    // Fields are `\u{1f}`-separated in the order id, window, active, path,
    // title -- title last so a title containing the separator stays intact.

    func test_parse_tmuxPaneList_decodesIdentityFocusAndWorkingDirectory() {
        let output = "%1\u{1f}@3\u{1f}1\u{1f}/repo\u{1f}editor\n%2\u{1f}@3\u{1f}0\u{1f}/tmp\u{1f}shell"

        XCTAssertEqual(
            PaneQuery.parse(output, backend: .tmux),
            [
                Pane(id: "%1", tabID: "@3", label: "editor", focused: true, status: .none, workspaceID: "@3", workingDirectory: "/repo"),
                Pane(id: "%2", tabID: "@3", label: "shell", focused: false, status: .none, workspaceID: "@3", workingDirectory: "/tmp")
            ]
        )
    }

    func test_parse_tmuxTitleContainingDelimiters_preservesTheTitle() {
        let output = "%1\u{1f}@3\u{1f}1\u{1f}/repo\u{1f}editor|with\u{1f}pipe"

        XCTAssertEqual(PaneQuery.parse(output, backend: .tmux)?.first?.label, "editor|with\u{1f}pipe")
    }

    func test_parse_tmuxPathContainingPipeAndUnicode_isPreserved() {
        let output = "%1\u{1f}@3\u{1f}1\u{1f}/src/a|b café\u{1f}shell"

        XCTAssertEqual(PaneQuery.parse(output, backend: .tmux)?.first?.workingDirectory, "/src/a|b café")
    }

    func test_parse_tmuxEmptyPath_isNil() {
        let output = "%1\u{1f}@3\u{1f}1\u{1f}\u{1f}shell"

        XCTAssertEqual(PaneQuery.parse(output, backend: .tmux), [
            Pane(id: "%1", tabID: "@3", label: "shell", focused: true, status: .none, workspaceID: "@3", workingDirectory: nil)
        ])
    }

    func test_parse_tmuxEmptyTitle_fallsBackToPaneID() {
        let output = "%1\u{1f}@3\u{1f}0\u{1f}/repo\u{1f}"

        XCTAssertEqual(PaneQuery.parse(output, backend: .tmux)?.first?.label, "%1")
    }

    func test_parse_tmuxMalformedLines_areDroppedWithoutFailingBatch() {
        let output = [
            "%1\u{1f}@3\u{1f}1\u{1f}/repo\u{1f}editor",
            "malformed",
            "%9\u{1f}@3\u{1f}yes\u{1f}/repo\u{1f}bad-active-flag",
            "\u{1f}@3\u{1f}0\u{1f}/repo\u{1f}missing-id",
            "%2\u{1f}@3\u{1f}0\u{1f}/tmp\u{1f}shell"
        ].joined(separator: "\n")

        XCTAssertEqual(PaneQuery.parse(output, backend: .tmux)?.map(\.id), ["%1", "%2"])
    }

    func test_parse_tmuxEmptyOutput_isEmpty() {
        XCTAssertEqual(PaneQuery.parse("", backend: .tmux), [])
    }
}
