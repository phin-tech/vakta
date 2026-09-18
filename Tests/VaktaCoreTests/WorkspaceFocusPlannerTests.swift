//
//  WorkspaceFocusPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `WorkspaceFocusPlanner.applying`: clicking a
//  workspace row fires the CLI switch off the main thread and doesn't wait
//  on it, so the sidebar's `focused` flags must flip locally, ahead of the
//  next real `fetchWorkspaces` confirming it -- otherwise the highlight only
//  moves after a manual collapse/re-expand.

import XCTest
@testable import Vakta

final class WorkspaceFocusPlannerTests: XCTestCase {
    private func workspace(_ id: String, focused: Bool) -> Workspace {
        Workspace(id: id, label: id, focused: focused)
    }

    func test_applying_marksTargetFocused_andClearsOthers() {
        let workspaces = [
            workspace("a", focused: true),
            workspace("b", focused: false),
            workspace("c", focused: false),
        ]
        let result = WorkspaceFocusPlanner.applying(focusing: "b", in: workspaces)
        XCTAssertEqual(result.map(\.focused), [false, true, false])
    }

    func test_applying_unknownID_leavesAllUnfocused() {
        let workspaces = [
            workspace("a", focused: true),
            workspace("b", focused: false),
        ]
        let result = WorkspaceFocusPlanner.applying(focusing: "missing", in: workspaces)
        XCTAssertEqual(result.map(\.focused), [false, false])
    }

    func test_applying_emptyInput_returnsEmpty() {
        XCTAssertEqual(WorkspaceFocusPlanner.applying(focusing: "a", in: []), [])
    }

    func test_applying_preservesOrderAndOtherFields() {
        let workspaces = [workspace("a", focused: false), workspace("b", focused: true)]
        let result = WorkspaceFocusPlanner.applying(focusing: "a", in: workspaces)
        XCTAssertEqual(result, [
            Workspace(id: "a", label: "a", focused: true),
            Workspace(id: "b", label: "b", focused: false),
        ])
    }
}
