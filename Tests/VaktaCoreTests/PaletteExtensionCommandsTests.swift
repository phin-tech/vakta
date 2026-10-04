//
//  PaletteExtensionCommandsTests.swift
//  VaktaCoreTests
//
//  Extension Commands in the ⌘K palette: after Vakta's own commands,
//  labelled with their Extension, committing (never drilling in).

import XCTest
@testable import Vakta

final class PaletteExtensionCommandsTests: XCTestCase {
    private let entry = PaletteItemAssembler.ExtensionCommandEntry(
        extensionID: "github", extensionName: "GitHub", id: "open-42", title: "Open PR #42"
    )

    func test_extensionCommands_followVaktasCommands_labelledWithTheirExtension() {
        let items = PaletteItemAssembler.assemble(
            sessions: [], workspaces: [:], workspaceStatus: [:], commands: [.toggleSidebar], extensionCommands: [entry]
        )
        XCTAssertEqual(items.map(\.id), ["action:\(AppCommand.toggleSidebar.stableID)", "extension:github:open-42"])
        XCTAssertEqual(items.last?.title, "Open PR #42")
        XCTAssertEqual(items.last?.subtitle, "GitHub")
        XCTAssertEqual(items.last?.category, .action)
        XCTAssertEqual(items.last?.kind, .extensionCommand(extensionID: "github", commandID: "open-42"))
    }

    func test_extensionCommand_commitsOnEnter_andDoesNotDrillOnTab() {
        let item = PaletteItemAssembler.assemble(sessions: [], workspaces: [:], workspaceStatus: [:], commands: [], extensionCommands: [entry])[0]
        XCTAssertEqual(PaletteNavigationPlanner.decide(intent: .enter, highlighted: item, scope: .root), .commit(item.kind))
        XCTAssertEqual(PaletteNavigationPlanner.decide(intent: .tab, highlighted: item, scope: .root), .noOp)
    }

    func test_extensionCommands_areSearchableByTitle() {
        let items = PaletteItemAssembler.assemble(sessions: [], workspaces: [:], workspaceStatus: [:], commands: [], extensionCommands: [entry])
        XCTAssertEqual(PaletteMatcher.matches(query: "open pr", in: items).map(\.id), ["extension:github:open-42"])
    }
}
