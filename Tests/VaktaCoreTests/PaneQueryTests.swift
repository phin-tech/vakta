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
                Pane(id: "w2G:p1", tabID: "w2G:t1", label: "claude", focused: true, status: .idle),
                Pane(id: "w2G:pB", tabID: "w2G:t5", label: "shell", focused: false, status: .none)
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

    func test_parse_tmuxPaneList_decodesWindowAndPaneIdentity() {
        let output = "%1|@3|editor|1\n%2|@3|shell|0"

        XCTAssertEqual(
            PaneQuery.parse(output, backend: .tmux),
            [
                Pane(id: "%1", tabID: "@3", label: "editor", focused: true, status: .none),
                Pane(id: "%2", tabID: "@3", label: "shell", focused: false, status: .none)
            ]
        )
    }

    func test_parse_tmuxTitleContainingDelimiter_preservesTheTitle() {
        let output = "%1|@3|editor|with|pipe|1"

        XCTAssertEqual(
            PaneQuery.parse(output, backend: .tmux),
            [Pane(id: "%1", tabID: "@3", label: "editor|with|pipe", focused: true, status: .none)]
        )
    }

    func test_parse_tmuxMalformedLines_areDroppedWithoutFailingBatch() {
        let output = "%1|@3|editor|1\nmalformed\n%2|@3|shell|0"

        XCTAssertEqual(
            PaneQuery.parse(output, backend: .tmux),
            [
                Pane(id: "%1", tabID: "@3", label: "editor", focused: true, status: .none),
                Pane(id: "%2", tabID: "@3", label: "shell", focused: false, status: .none)
            ]
        )
    }

    func test_parse_tmuxEmptyOutput_isEmpty() {
        XCTAssertEqual(PaneQuery.parse("", backend: .tmux), [])
    }
}
