//
//  SessionSwitcherHierarchyTests.swift
//  VaktaCoreTests
//
//  RED tests for the live scoped palette model behind Cmd-K.

import XCTest
@testable import Vakta

@MainActor
final class SessionSwitcherHierarchyTests: XCTestCase {
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private var sessionItem: PaletteItem {
        PaletteItem(
            id: "session:\(sessionID.uuidString)",
            title: "Herdr · default",
            subtitle: "herdr",
            category: .session,
            status: .idle,
            kind: .selectSession(sessionID)
        )
    }

    private var workspaceItem: PaletteItem {
        PaletteItem(
            id: "workspace:\(sessionID.uuidString):w2G",
            title: "guildhall",
            subtitle: "Herdr · default",
            category: .workspace,
            status: .none,
            kind: .focusWorkspace(sessionID: sessionID, workspaceID: "w2G")
        )
    }

    func test_showScope_workspacesReplacesRowsAndRecordsScope() {
        let model = SessionSwitcherModel()
        model.reset(items: [sessionItem])

        model.showScope(.workspaces(sessionID: sessionID), items: [workspaceItem])

        XCTAssertEqual(model.scope, .workspaces(sessionID: sessionID))
        XCTAssertEqual(model.matches, [workspaceItem])
    }

    func test_goBack_fromWorkspaceScopeRestoresRootRows() {
        let model = SessionSwitcherModel()
        model.reset(items: [sessionItem])
        model.showScope(.workspaces(sessionID: sessionID), items: [workspaceItem])

        model.goBack()

        XCTAssertEqual(model.scope, .root)
        XCTAssertEqual(model.matches, [sessionItem])
    }

    func test_showScope_resetsQueryAndHighlightForTheNewLevel() {
        let model = SessionSwitcherModel()
        model.reset(items: [sessionItem, workspaceItem])
        model.query = "herdr"
        model.moveDown()

        model.showScope(.workspaces(sessionID: sessionID), items: [workspaceItem])

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.highlighted, 0)
    }
}
