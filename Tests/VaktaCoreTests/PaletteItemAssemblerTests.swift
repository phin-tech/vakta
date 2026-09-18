//
//  PaletteItemAssemblerTests.swift
//  VaktaCoreTests
//
//  RED, slice 1 of the ⌘K command palette generalization (see docs/testing.md
//  "Session switcher"). Pure assembly: sessions + their known herdr
//  workspaces + static actions -> one ordered PaletteItem list.

import XCTest
@testable import Vakta

final class PaletteItemAssemblerTests: XCTestCase {
    private func session(_ title: String, status: AgentStatus = .none) -> (UUID, PaletteItemAssembler.SessionEntry) {
        let id = UUID()
        return (id, PaletteItemAssembler.SessionEntry(id: id, title: title, status: status))
    }

    func test_assemble_emptyInputs_isEmpty() {
        let items = PaletteItemAssembler.assemble(
            sessions: [],
            workspaces: [:],
            workspaceStatus: [:],
            actions: []
        )

        XCTAssertTrue(items.isEmpty)
    }

    func test_assemble_sessionsBecomeSelectSessionItems_inOrder() {
        let (id1, entry1) = session("alpha", status: .working)
        let (id2, entry2) = session("beta", status: .idle)

        let items = PaletteItemAssembler.assemble(
            sessions: [entry1, entry2],
            workspaces: [:],
            workspaceStatus: [:],
            actions: []
        )

        XCTAssertEqual(items.map(\.title), ["alpha", "beta"])
        XCTAssertEqual(items.map(\.category), [.session, .session])
        XCTAssertEqual(items.map(\.kind), [.selectSession(id1), .selectSession(id2)])
        XCTAssertEqual(items.map(\.status), [.working, .idle])
    }

    func test_assemble_sessionWithNoWorkspaces_producesNoWorkspaceRows() {
        let (_, entry) = session("alpha")

        let items = PaletteItemAssembler.assemble(
            sessions: [entry],
            workspaces: [:],
            workspaceStatus: [:],
            actions: []
        )

        XCTAssertEqual(items.count, 1)
    }

    func test_assemble_workspacesAppearAfterTheirOwningSession_withSessionTitleAsSubtitle() {
        let (id, entry) = session("alpha")
        let workspace = Workspace(id: "w1", label: "guildhall", focused: false)

        let items = PaletteItemAssembler.assemble(
            sessions: [entry],
            workspaces: [id: [workspace]],
            workspaceStatus: ["w1": .attention],
            actions: []
        )

        XCTAssertEqual(items.map(\.title), ["alpha", "guildhall"])
        XCTAssertEqual(items[1].category, .workspace)
        XCTAssertEqual(items[1].subtitle, "alpha")
        XCTAssertEqual(items[1].status, .attention)
        XCTAssertEqual(items[1].kind, .focusWorkspace(sessionID: id, workspaceID: "w1"))
    }

    func test_assemble_workspaceStatus_missingEntry_fallsBackToNone() {
        let (id, entry) = session("alpha")
        let workspace = Workspace(id: "w1", label: "guildhall", focused: false)

        let items = PaletteItemAssembler.assemble(
            sessions: [entry],
            workspaces: [id: [workspace]],
            workspaceStatus: [:],
            actions: []
        )

        XCTAssertEqual(items[1].status, .none)
    }

    func test_assemble_multipleSessions_workspacesFollowEachOwningSession_notGroupedGlobally() {
        let (id1, entry1) = session("alpha")
        let (id2, entry2) = session("beta")
        let w1 = Workspace(id: "w1", label: "one", focused: false)
        let w2 = Workspace(id: "w2", label: "two", focused: false)

        let items = PaletteItemAssembler.assemble(
            sessions: [entry1, entry2],
            workspaces: [id1: [w1], id2: [w2]],
            workspaceStatus: [:],
            actions: []
        )

        XCTAssertEqual(items.map(\.title), ["alpha", "one", "beta", "two"])
    }

    func test_assemble_actionsAppearLast_asActionCategory() {
        let (_, entry) = session("alpha")
        let action = PaletteAction(id: "toggleSidebar", title: "Toggle Sidebar")

        let items = PaletteItemAssembler.assemble(
            sessions: [entry],
            workspaces: [:],
            workspaceStatus: [:],
            actions: [action]
        )

        XCTAssertEqual(items.map(\.title), ["alpha", "Toggle Sidebar"])
        XCTAssertEqual(items[1].category, .action)
        XCTAssertEqual(items[1].kind, .action(id: "toggleSidebar"))
        XCTAssertEqual(items[1].status, .none)
    }

    func test_assemble_itemIDs_areUniqueAcrossCategories() {
        let (id, entry) = session("alpha")
        let workspace = Workspace(id: "w1", label: "guildhall", focused: false)
        let action = PaletteAction(id: "toggleSidebar", title: "Toggle Sidebar")

        let items = PaletteItemAssembler.assemble(
            sessions: [entry],
            workspaces: [id: [workspace]],
            workspaceStatus: [:],
            actions: [action]
        )

        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }
}
