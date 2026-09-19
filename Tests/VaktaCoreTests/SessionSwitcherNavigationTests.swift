//
//  SessionSwitcherNavigationTests.swift
//  VaktaCoreTests
//
//  RED tests for the model-level Cmd-K navigation contract. The panel routes
//  key events here; the app shell supplies fetched rows for requested scopes.

import XCTest
@testable import Vakta

@MainActor
final class SessionSwitcherNavigationTests: XCTestCase {
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func sessionItem() -> PaletteItem {
        PaletteItem(
            id: "session:\(sessionID.uuidString)",
            title: "Herdr · default",
            subtitle: "herdr",
            category: .session,
            status: .idle,
            kind: .selectSession(sessionID)
        )
    }

    private func workspaceItem() -> PaletteItem {
        PaletteItem(
            id: "workspace:\(sessionID.uuidString):w2G",
            title: "guildhall",
            subtitle: "Herdr · default",
            category: .workspace,
            status: .none,
            kind: .focusWorkspace(sessionID: sessionID, workspaceID: "w2G")
        )
    }

    func test_navigateTab_requestsTheHighlightedSessionsWorkspaceScope() {
        let model = SessionSwitcherModel()
        model.reset(items: [sessionItem()])
        var requestedScope: PaletteNavigationScope?
        model.onScopeRequested = { requestedScope = $0 }

        model.navigate(.tab)

        XCTAssertEqual(requestedScope, .workspaces(sessionID: sessionID))
    }

    func test_navigateTab_inWorkspaceScope_requestsPaneScope() {
        let model = SessionSwitcherModel()
        model.reset(items: [sessionItem()])
        model.showScope(.workspaces(sessionID: sessionID), items: [workspaceItem()])
        var requestedScope: PaletteNavigationScope?
        model.onScopeRequested = { requestedScope = $0 }

        model.navigate(.tab)

        XCTAssertEqual(requestedScope, .panes(sessionID: sessionID, workspaceID: "w2G"))
    }

    func test_navigateShiftTab_restoresParentScope() {
        let model = SessionSwitcherModel()
        model.reset(items: [sessionItem()])
        model.showScope(.workspaces(sessionID: sessionID), items: [workspaceItem()])

        model.navigate(.shiftTab)

        XCTAssertEqual(model.scope, .root)
        XCTAssertEqual(model.matches, [sessionItem()])
    }

    func test_navigateEscape_atRoot_cancelsThePalette() {
        let model = SessionSwitcherModel()
        model.reset(items: [sessionItem()])
        var cancelled = false
        model.onCancel = { cancelled = true }

        model.navigate(.escape)

        XCTAssertTrue(cancelled)
    }
}
