//
//  WorkspaceQueryTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `WorkspaceQuery.parse`: turning `herdr
//  workspace list`'s JSON into `[Workspace]`, mirroring `HerdrAgentStatus`'s
//  decode-and-ignore-unknown-keys shape. No process execution here -- see
//  `LaunchTargetShellTests` for that.
//
//  Fixture payloads are the real shape (`herdr --session <name> workspace
//  list` against a live local session, checked by hand -- not vendored/
//  documented in this repo): `result.workspaces[]` with `workspace_id`,
//  `label`, `focused`, plus fields this feature doesn't need yet
//  (`agent_status`, `number`, `tab_count`, `pane_count`, `active_tab_id`).

import XCTest
@testable import Vakta

final class WorkspaceQueryTests: XCTestCase {
    func test_parse_validPayload_decodesWorkspaces() {
        // Verbatim `herdr --session default workspace list` output, captured
        // against a live local session -- top-level `id`/`result.type` and
        // all fields included, not just the ones this feature reads.
        let json = #"{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"active_tab_id":"w2C:t1","agent_status":"idle","focused":false,"label":"guildhall","number":1,"pane_count":2,"tab_count":1,"workspace_id":"w2C"},{"active_tab_id":"w2D:t1","agent_status":"working","focused":false,"label":"vakta","number":2,"pane_count":2,"tab_count":1,"workspace_id":"w2D"},{"active_tab_id":"w2E:t1","agent_status":"idle","focused":true,"label":"data-platform","number":3,"pane_count":1,"tab_count":1,"workspace_id":"w2E"}]}}"#
        XCTAssertEqual(
            WorkspaceQuery.parse(json, backend: .herdr),
            [
                Workspace(id: "w2C", label: "guildhall", focused: false),
                Workspace(id: "w2D", label: "vakta", focused: false),
                Workspace(id: "w2E", label: "data-platform", focused: true),
            ]
        )
    }

    func test_parse_emptyList_isEmptyNotNil() {
        let json = #"{"result":{"workspaces":[]}}"#
        XCTAssertEqual(WorkspaceQuery.parse(json, backend: .herdr), [])
    }

    func test_parse_errorPayload_isNil() {
        // The shape `herdr` returns on a socket/protocol failure (also
        // reachable with a live session name that doesn't resolve, or a
        // future error path that returns JSON on stdout with exit 0).
        let json = #"{"id":"cli:workspace:list","error":{"code":"server_not_running","message":"no herdr server is running"}}"#
        XCTAssertNil(WorkspaceQuery.parse(json, backend: .herdr))
    }

    func test_parse_malformedJSON_isNil() {
        XCTAssertNil(WorkspaceQuery.parse("not json", backend: .herdr))
    }

    func test_parse_ignoresUnknownKeys() {
        let json = #"""
        {"result":{"workspaces":[
            {"workspace_id":"w2D","label":"vakta","focused":false,"agent_status":"working","number":2,"tab_count":1,"pane_count":2,"active_tab_id":"w2D:t1"}
        ]}}
        """#
        XCTAssertEqual(WorkspaceQuery.parse(json, backend: .herdr), [Workspace(id: "w2D", label: "vakta", focused: false)])
    }

    // MARK: tmux windows

    func test_parse_tmux_pipeSeparatedLines_decodesWindows() {
        // `|`, not a tab: tmux's `-F` engine substitutes "unprintable" bytes
        // (including tab) with `_` when it can't detect a UTF-8 locale --
        // which the actual process environment never provides (see
        // `ProcessRunner.run` and `LaunchTargetShellTests`'s real-tmux
        // regression test).
        let output = "@1|guildhall|1\n@2|vakta|0"
        XCTAssertEqual(
            WorkspaceQuery.parse(output, backend: .tmux),
            [
                Workspace(id: "@1", label: "guildhall", focused: true),
                Workspace(id: "@2", label: "vakta", focused: false),
            ]
        )
    }

    func test_parse_tmux_emptyOutput_isEmptyNotNil() {
        XCTAssertEqual(WorkspaceQuery.parse("", backend: .tmux), [])
    }

    func test_parse_tmux_malformedLine_isDropped() {
        let output = "@1|guildhall|1\nnot-enough-fields\n@2|vakta|0"
        XCTAssertEqual(
            WorkspaceQuery.parse(output, backend: .tmux),
            [
                Workspace(id: "@1", label: "guildhall", focused: true),
                Workspace(id: "@2", label: "vakta", focused: false),
            ]
        )
    }

    func test_parse_tmux_windowNameContainingDelimiter_staysIntact() {
        // A window name with `|` in it must not corrupt the split -- only
        // the first and last `|` are structural.
        let output = "@1|left|right|1"
        XCTAssertEqual(WorkspaceQuery.parse(output, backend: .tmux), [Workspace(id: "@1", label: "left|right", focused: true)])
    }
}
