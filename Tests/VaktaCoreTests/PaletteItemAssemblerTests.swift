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
            commands: []
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
            commands: []
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
            commands: []
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
            commands: []
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
            commands: []
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
            commands: []
        )

        XCTAssertEqual(items.map(\.title), ["alpha", "one", "beta", "two"])
    }

    func test_assembleGlobalPanes_usesPaneNameAndSessionWorkspaceContext() {
        let sessionID = UUID()
        let pane = Pane(id: "w2C:p4", tabID: "w2C:t1", label: "test-123", focused: true, status: .none)
        let items = PaletteItemAssembler.assembleGlobalPanes([
            PaletteItemAssembler.GlobalPaneEntry(
                pane: pane,
                sessionID: sessionID,
                sessionTitle: "default",
                workspaceID: "w2C",
                workspaceTitle: "guildhall"
            )
        ])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "test-123")
        XCTAssertEqual(items[0].subtitle, "default / guildhall")
        XCTAssertEqual(items[0].category, .pane)
        XCTAssertEqual(items[0].kind, .focusPane(sessionID: sessionID, workspaceID: "w2C", paneID: "w2C:p4"))
    }

    func test_assemble_actionsAppearLast_asActionCategory() {
        let (_, entry) = session("alpha")
        let items = PaletteItemAssembler.assemble(
            sessions: [entry],
            workspaces: [:],
            workspaceStatus: [:],
            commands: [.toggleSidebar, .splitPaneRight]
        )

        XCTAssertEqual(items.map(\.title), ["alpha", "Toggle Sidebar", "Split Pane Right"])
        XCTAssertEqual(items[1].category, .action)
        XCTAssertEqual(items[1].kind, .command(.toggleSidebar))
        XCTAssertEqual(items[1].status, .none)
        XCTAssertEqual(items[2].kind, .command(.splitPaneRight))
    }

    func test_assemble_commandRowIDs_keepTheLegacyActionPrefix() {
        let items = PaletteItemAssembler.assemble(
            sessions: [],
            workspaces: [:],
            workspaceStatus: [:],
            commands: AppCommandCatalog.paletteCommands
        )
        XCTAssertEqual(items.map(\.id), AppCommandCatalog.paletteCommands.map { "action:\($0.stableID)" })
        XCTAssertEqual(items.first?.id, "action:newSession")
    }

    func test_assemble_itemIDs_areUniqueAcrossCategories() {
        let (id, entry) = session("alpha")
        let workspace = Workspace(id: "w1", label: "guildhall", focused: false)
        let items = PaletteItemAssembler.assemble(
            sessions: [entry],
            workspaces: [id: [workspace]],
            workspaceStatus: [:],
            commands: [.toggleSidebar]
        )

        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func test_assemble_attachesLeaderSequences_toCommandRowsThatHaveOne() {
        let items = PaletteItemAssembler.assemble(
            sessions: [],
            workspaces: [:],
            workspaceStatus: [:],
            commands: [.toggleFileSidebar, .newSession],
            leaderSequences: [.toggleFileSidebar: "o f"]
        )
        XCTAssertEqual(items.map(\.leaderSequence), ["o f", nil])
    }

    func test_assemble_withoutLeaderSequences_leavesRowsWithoutOne() {
        let items = PaletteItemAssembler.assemble(
            sessions: [], workspaces: [:], workspaceStatus: [:], commands: [.toggleFileSidebar]
        )
        XCTAssertNil(items[0].leaderSequence)
    }
}
