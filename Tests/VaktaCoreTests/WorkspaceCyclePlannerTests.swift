//
//  WorkspaceCyclePlannerTests.swift
//  VaktaCoreTests
//
//  "Next/Previous Workspace": which workspace to focus, given the session's
//  workspaces (in the backend's order) and which one is focused.

import XCTest
@testable import Vakta

final class WorkspaceCyclePlannerTests: XCTestCase {
    private func workspaces(_ ids: [String], focused: String?) -> [Workspace] {
        ids.map { Workspace(id: $0, label: $0, focused: $0 == focused) }
    }

    func test_nextAndPrevious_fromTheFocusedWorkspace() {
        let list = workspaces(["a", "b", "c"], focused: "b")
        XCTAssertEqual(WorkspaceCyclePlanner.target(in: list, offset: 1), "c")
        XCTAssertEqual(WorkspaceCyclePlanner.target(in: list, offset: -1), "a")
    }

    func test_wrapsAroundBothEnds() {
        XCTAssertEqual(WorkspaceCyclePlanner.target(in: workspaces(["a", "b", "c"], focused: "c"), offset: 1), "a")
        XCTAssertEqual(WorkspaceCyclePlanner.target(in: workspaces(["a", "b", "c"], focused: "a"), offset: -1), "c")
    }

    func test_nothingFocused_startsFromTheEdge() {
        let list = workspaces(["a", "b", "c"], focused: nil)
        XCTAssertEqual(WorkspaceCyclePlanner.target(in: list, offset: 1), "a")
        XCTAssertEqual(WorkspaceCyclePlanner.target(in: list, offset: -1), "c")
    }

    func test_noWorkspaceToMoveTo_isNil() {
        XCTAssertNil(WorkspaceCyclePlanner.target(in: [], offset: 1))
        XCTAssertNil(WorkspaceCyclePlanner.target(in: workspaces(["a"], focused: "a"), offset: 1), "already there")
    }
}
