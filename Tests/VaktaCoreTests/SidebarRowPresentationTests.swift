//
//  SidebarRowPresentationTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `SidebarRowPresentation`: which sidebar rows
//  get a highlight or a status mark. Before this, every session's focused
//  workspace drew the same pill as the selected session's, so an expanded
//  sidebar read as having several selections at once; and a session with no
//  agent drew a gray dot that carried no information.

import XCTest
@testable import Vakta

final class SidebarRowPresentationTests: XCTestCase {
    func test_focusedWorkspace_underTheSelectedSession_isProminent() {
        XCTAssertEqual(
            SidebarRowPresentation.workspaceHighlight(workspaceFocused: true, sessionSelected: true),
            .prominent
        )
    }

    func test_focusedWorkspace_underAnUnselectedSession_isOnlySubtle() {
        // Still worth showing -- it's where that session will land when
        // selected -- but it must not compete with the real selection.
        XCTAssertEqual(
            SidebarRowPresentation.workspaceHighlight(workspaceFocused: true, sessionSelected: false),
            .subtle
        )
    }

    func test_unfocusedWorkspace_hasNoHighlight_whateverItsSession() {
        XCTAssertEqual(SidebarRowPresentation.workspaceHighlight(workspaceFocused: false, sessionSelected: true), .none)
        XCTAssertEqual(SidebarRowPresentation.workspaceHighlight(workspaceFocused: false, sessionSelected: false), .none)
    }

    func test_statusMark_isShownForEveryStatusThatReportsOnAnAgent() {
        for status in [AgentStatus.working, .attention, .done, .idle] {
            XCTAssertTrue(SidebarRowPresentation.showsStatusMark(status), "\(status)")
        }
    }

    func test_statusMark_isHiddenWhenThereIsNoAgentToReportOn() {
        XCTAssertFalse(SidebarRowPresentation.showsStatusMark(.none))
        XCTAssertFalse(SidebarRowPresentation.showsStatusMark(.unavailable))
    }
}
