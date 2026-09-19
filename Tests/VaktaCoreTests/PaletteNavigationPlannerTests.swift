//
//  PaletteNavigationPlannerTests.swift
//  VaktaCoreTests
//
//  RED tests for hierarchical Cmd-K navigation:
//  client/session -> workspaces/windows -> panes.
//

import XCTest
@testable import Vakta

final class PaletteNavigationPlannerTests: XCTestCase {
    private let clientID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let workspaceID = "w2G"
    private let paneID = "w2G:p1"

    private var sessionItem: PaletteItem {
        PaletteItem(
            id: "session:\(clientID.uuidString)",
            title: "Herdr · default",
            subtitle: "herdr",
            category: .session,
            status: .idle,
            kind: .selectSession(clientID)
        )
    }

    private var workspaceItem: PaletteItem {
        PaletteItem(
            id: "workspace:\(clientID.uuidString):\(workspaceID)",
            title: "guildhall",
            subtitle: "Herdr · default",
            category: .workspace,
            status: .working,
            kind: .focusWorkspace(sessionID: clientID, workspaceID: workspaceID)
        )
    }

    private var paneItem: PaletteItem {
        PaletteItem(
            id: "pane:\(clientID.uuidString):\(workspaceID):\(paneID)",
            title: "claude",
            subtitle: "guildhall",
            category: .pane,
            status: .working,
            kind: .focusPane(
                sessionID: clientID,
                workspaceID: workspaceID,
                paneID: paneID
            )
        )
    }

    func test_tab_onSession_drillsIntoItsWorkspaces() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .tab,
                highlighted: sessionItem,
                scope: .root
            ),
            .drillInto(.workspaces(sessionID: clientID))
        )
    }

    func test_tab_onWorkspace_drillsIntoItsPanes() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .tab,
                highlighted: workspaceItem,
                scope: .workspaces(sessionID: clientID)
            ),
            .drillInto(.panes(sessionID: clientID, workspaceID: workspaceID))
        )
    }

    func test_enter_onSession_commitsImmediatelyInsteadOfDrilling() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .enter,
                highlighted: sessionItem,
                scope: .root
            ),
            .commit(.selectSession(clientID))
        )
    }

    func test_enter_onWorkspace_commitsImmediatelyInsteadOfDrilling() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .enter,
                highlighted: workspaceItem,
                scope: .workspaces(sessionID: clientID)
            ),
            .commit(.focusWorkspace(sessionID: clientID, workspaceID: workspaceID))
        )
    }

    func test_enter_onPane_commitsImmediately() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .enter,
                highlighted: paneItem,
                scope: .panes(sessionID: clientID, workspaceID: workspaceID)
            ),
            .commit(.focusPane(
                sessionID: clientID,
                workspaceID: workspaceID,
                paneID: paneID
            ))
        )
    }

    func test_tab_onPane_isANoOpBecausePanesAreLeaves() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .tab,
                highlighted: paneItem,
                scope: .panes(sessionID: clientID, workspaceID: workspaceID)
            ),
            .noOp
        )
    }

    func test_shiftTab_fromWorkspaceScope_goesBackToRoot() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .shiftTab,
                highlighted: workspaceItem,
                scope: .workspaces(sessionID: clientID)
            ),
            .back
        )
    }

    func test_escape_fromPaneScope_goesBackInsteadOfClosing() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .escape,
                highlighted: paneItem,
                scope: .panes(sessionID: clientID, workspaceID: workspaceID)
            ),
            .back
        )
    }

    func test_escape_atRoot_dismissesPalette() {
        XCTAssertEqual(
            PaletteNavigationPlanner.decide(
                intent: .escape,
                highlighted: sessionItem,
                scope: .root
            ),
            .dismiss
        )
    }
}
