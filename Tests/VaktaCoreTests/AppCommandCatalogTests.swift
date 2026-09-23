//
//  AppCommandCatalogTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the unified command registry (see
//  docs/command-registry-plan.md): `AppCommandCatalog`'s ordered lists and
//  `CommandAvailability`'s capability gate. Pure values only.

import XCTest
@testable import Vakta

final class AppCommandCatalogTests: XCTestCase {
    /// The ⌘K static rows as they shipped before the registry existed, in
    /// order, with their original ids and titles.
    private let legacyPaletteRows: [(id: String, title: String)] = [
        ("newSession", "New Session"),
        ("toggleSidebar", "Toggle Sidebar"),
        ("toggleFileSidebar", "Toggle File Sidebar"),
        ("openPreferences", "Open Preferences"),
        ("openInEditor", "Open in Editor"),
        ("splitPaneRight", "Split Pane Right"),
        ("splitPaneDown", "Split Pane Down"),
        ("zoomPane", "Zoom Pane"),
        ("closePane", "Close Pane"),
        ("renamePane", "Rename Pane…"),
        ("closeWorkspace", "Close Workspace"),
        ("newWorkspace", "New Workspace"),
        ("stopSession", "Stop Session"),
        ("editHerdrConfig", "Edit Herdr Config…"),
        ("reloadHerdrConfig", "Reload Herdr Config"),
        ("increaseFontSize", "Increase Font Size"),
        ("decreaseFontSize", "Decrease Font Size"),
        ("resetFontSize", "Reset Font Size"),
    ]

    func test_paletteCommands_matchTheLegacyStaticRows_inOrder_withSameIDsAndTitles() {
        let rows = AppCommandCatalog.paletteCommands.map { (id: $0.stableID, title: $0.title) }
        XCTAssertEqual(rows.map(\.id), legacyPaletteRows.map(\.id))
        XCTAssertEqual(rows.map(\.title), legacyPaletteRows.map(\.title))
    }

    func test_chordOnlyCommands_keepTheirExistingTitles() {
        XCTAssertEqual(AppCommand.openSessionSwitcher.title, "Command Palette")
        XCTAssertEqual(AppCommand.selectSession(0).title, "Select Session 1")
        XCTAssertEqual(AppCommand.nextUnreadSession.title, "Next Unread Session")
        XCTAssertEqual(AppCommand.closeWindow.title, "Close Window")
    }

    func test_stableIDs_areUniqueAcrossBindableCommands() {
        let ids = AppCommandCatalog.bindableCommands.map(\.stableID)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate stableID in \(ids)")
    }

    func test_selectSession_stableID_carriesItsIndex() {
        XCTAssertEqual(AppCommand.selectSession(3).stableID, "selectSession.3")
    }

    func test_bindableCommands_isExactlyTheUnionOfChordAndPaletteCommands_onceEach() {
        let chordCommands: [AppCommand] = (0..<9).map { .selectSession($0) } + [
            .toggleSidebar, .openPreferences, .openSessionSwitcher, .quit,
            .copy, .paste, .cut, .selectAll, .closeWindow,
            .increaseFontSize, .decreaseFontSize, .resetFontSize, .nextUnreadSession,
        ]
        let workspaceSlots: [AppCommand] = (0..<9).map { .focusWorkspace($0) }
        let paletteOnly: [AppCommand] = [
            .newSession, .toggleFileSidebar, .openInEditor,
            .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane,
            .closeWorkspace, .newWorkspace, .stopSession,
            .editHerdrConfig, .reloadHerdrConfig,
        ]
        let bindable = AppCommandCatalog.bindableCommands

        XCTAssertEqual(bindable.count, Set(bindable).count, "a command is listed twice")
        XCTAssertEqual(Set(bindable), Set(chordCommands + paletteOnly + workspaceSlots))
    }

    func test_focusWorkspace_titleAndStableID_carryItsPosition() {
        XCTAssertEqual(AppCommand.focusWorkspace(0).title, "Focus Workspace 1")
        XCTAssertEqual(AppCommand.focusWorkspace(4).stableID, "focusWorkspace.4")
        XCTAssertEqual(AppCommand.focusWorkspace(0).group, .workspaces)
    }

    func test_focusWorkspace_isNotAPaletteRow() {
        // ⌘K already lists workspaces by name as navigation rows.
        XCTAssertFalse(AppCommandCatalog.paletteCommands.contains { if case .focusWorkspace = $0 { return true } else { return false } })
    }

    func test_bindableCommands_includesNextUnreadSession_soPreferencesCanRebindIt() {
        // Regression: ⌘U shipped as a default chord but was missing from the
        // hand-written Preferences list, so it could not be rebound or cleared.
        XCTAssertTrue(AppCommandCatalog.bindableCommands.contains(.nextUnreadSession))
    }
}

final class CommandAvailabilityTests: XCTestCase {
    private let multiplexerCommands: [AppCommand] = [
        .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane,
        .closeWorkspace, .newWorkspace, .stopSession,
    ]

    private var otherPaletteCommands: [AppCommand] {
        AppCommandCatalog.paletteCommands.filter { !multiplexerCommands.contains($0) }
    }

    func test_multiplexerCommands_unavailable_whenSelectedSessionDoesNotSupportActions() {
        let context = CommandContext(supportsSelectedSessionActions: false)
        for command in multiplexerCommands {
            XCTAssertFalse(CommandAvailability.isAvailable(command, in: context), "\(command)")
        }
    }

    func test_multiplexerCommands_available_whenSelectedSessionSupportsActions() {
        let context = CommandContext(supportsSelectedSessionActions: true)
        for command in multiplexerCommands {
            XCTAssertTrue(CommandAvailability.isAvailable(command, in: context), "\(command)")
        }
    }

    func test_nonMultiplexerCommands_alwaysAvailable() {
        XCTAssertFalse(otherPaletteCommands.isEmpty)
        for supports in [false, true] {
            let context = CommandContext(supportsSelectedSessionActions: supports)
            for command in otherPaletteCommands + [.quit, .nextUnreadSession] {
                XCTAssertTrue(
                    CommandAvailability.isAvailable(command, in: context),
                    "\(command) must not depend on the selected session (supports=\(supports))"
                )
            }
        }
    }

    func test_availablePaletteCommands_withoutSupport_dropsExactlyTheMultiplexerRows() {
        let context = CommandContext(supportsSelectedSessionActions: false)
        let visible = AppCommandCatalog.paletteCommands.filter { CommandAvailability.isAvailable($0, in: context) }
        XCTAssertEqual(visible, otherPaletteCommands)
        XCTAssertEqual(visible.count, 10)
    }

    func test_selectSession_availableOnlyWhenASessionExistsAtThatIndex() {
        let context = CommandContext(supportsSelectedSessionActions: false, sessionTitles: ["alpha", "beta"])
        XCTAssertTrue(CommandAvailability.isAvailable(.selectSession(0), in: context))
        XCTAssertTrue(CommandAvailability.isAvailable(.selectSession(1), in: context))
        XCTAssertFalse(CommandAvailability.isAvailable(.selectSession(2), in: context))
        XCTAssertFalse(CommandAvailability.isAvailable(.selectSession(-1), in: context))
    }

    func test_selectSession_unavailableWithNoSessions() {
        let context = CommandContext(supportsSelectedSessionActions: true)
        XCTAssertFalse(CommandAvailability.isAvailable(.selectSession(0), in: context))
    }

    func test_focusWorkspace_availableOnlyWhenTheSelectedSessionHasThatWorkspace() {
        let context = CommandContext(supportsSelectedSessionActions: true, workspaceTitles: ["guildhall", "notes"])
        XCTAssertTrue(CommandAvailability.isAvailable(.focusWorkspace(0), in: context))
        XCTAssertTrue(CommandAvailability.isAvailable(.focusWorkspace(1), in: context))
        XCTAssertFalse(CommandAvailability.isAvailable(.focusWorkspace(2), in: context))
        XCTAssertFalse(CommandAvailability.isAvailable(.focusWorkspace(0), in: CommandContext(supportsSelectedSessionActions: true)))
    }
}
