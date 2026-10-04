//
//  StatusBarTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the status bar: its visibility preference
//  (decode, cycle), what it shows for the focused pane (branch, one PR
//  glyph, a count of other PRs needing attention), and when the docked bar
//  is present.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class StatusBarTests: XCTestCase {
    // MARK: visibility preference

    func test_preferences_defaultToAuto_andDecodeMissingOrUnknownAsAuto() throws {
        XCTAssertEqual(StatusBarPreferences().visibility, .auto)
        XCTAssertEqual(try JSONDecoder().decode(StatusBarPreferences.self, from: Data("{}".utf8)).visibility, .auto)
        XCTAssertEqual(try JSONDecoder().decode(StatusBarPreferences.self, from: Data(#"{"visibility":"sideways"}"#.utf8)).visibility, .auto)
    }

    func test_preferences_roundTripEveryVisibility() throws {
        for visibility in StatusBarVisibility.allCases {
            let data = try JSONEncoder().encode(StatusBarPreferences(visibility: visibility))
            XCTAssertEqual(try JSONDecoder().decode(StatusBarPreferences.self, from: data).visibility, visibility)
        }
    }

    func test_visibility_cyclesThroughEveryMode() {
        XCTAssertEqual(StatusBarVisibility.auto.next, .autoHide)
        XCTAssertEqual(StatusBarVisibility.autoHide.next, .show)
        XCTAssertEqual(StatusBarVisibility.show.next, .hide)
        XCTAssertEqual(StatusBarVisibility.hide.next, .auto)
    }

    // MARK: keyboard

    func test_listKeys_mapArrowsReturnAndEscape_ignoringModifiedKeys() {
        XCTAssertEqual(StatusBarListKey.action(keyCode: 126, hasModifiers: false), .up)
        XCTAssertEqual(StatusBarListKey.action(keyCode: 125, hasModifiers: false), .down)
        XCTAssertEqual(StatusBarListKey.action(keyCode: 36, hasModifiers: false), .open)
        XCTAssertEqual(StatusBarListKey.action(keyCode: 76, hasModifiers: false), .open, "keypad Enter")
        XCTAssertEqual(StatusBarListKey.action(keyCode: 53, hasModifiers: false), .close)
        XCTAssertNil(StatusBarListKey.action(keyCode: 0, hasModifiers: false))
        XCTAssertNil(StatusBarListKey.action(keyCode: 126, hasModifiers: true))
    }

    func test_selection_startsAtTheEdge_andClamps() {
        XCTAssertEqual(StatusBarListKey.moved(nil, by: 1, count: 3), 0)
        XCTAssertEqual(StatusBarListKey.moved(nil, by: -1, count: 3), 2)
        XCTAssertEqual(StatusBarListKey.moved(1, by: 1, count: 3), 2)
        XCTAssertEqual(StatusBarListKey.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(StatusBarListKey.moved(0, by: -1, count: 3), 0)
        XCTAssertNil(StatusBarListKey.moved(nil, by: 1, count: 0))
        XCTAssertEqual(StatusBarListKey.moved(5, by: 0, count: 3), 2, "clamped when the list shrank")
    }

    // MARK: docked presence

    func test_isDocked_perVisibility() {
        let empty = StatusBarContent()
        let branch = StatusBarContent(extensionItems: ExtensionStatusItems.merge(
            ["github": StatusSetParams(placement: .leading, segments: [StatusSegment(text: "main")])], order: ["github"]))

        XCTAssertTrue(StatusBarPresentation.isDocked(.show, content: empty))
        XCTAssertFalse(StatusBarPresentation.isDocked(.hide, content: branch))
        XCTAssertFalse(StatusBarPresentation.isDocked(.auto, content: empty))
        XCTAssertTrue(StatusBarPresentation.isDocked(.auto, content: branch))
        XCTAssertFalse(StatusBarPresentation.isDocked(.autoHide, content: branch), "auto-hide overlays; it never docks")
    }

    // MARK: commands

    func test_statusBarCommands_haveTitlesStableIDsAndLeaderSequences() {
        XCTAssertEqual(AppCommand.cycleStatusBar.title, "Cycle Status Bar Visibility")
        XCTAssertEqual(AppCommand.cycleStatusBar.stableID, "cycleStatusBar")

        XCTAssertEqual(AppCommand.showStatusBarBriefly.title, "Show Status Bar Briefly")
        XCTAssertEqual(AppCommand.showStatusBarBriefly.stableID, "showStatusBarBriefly")

        let paths = LeaderTree.defaultRoot.commandPaths()
        XCTAssertEqual(paths[.showStatusBarBriefly], [31, 11], "o b")
        XCTAssertEqual(paths[.cycleStatusBar], [31, 9], "o v")
        for command in [AppCommand.showStatusBarBriefly, .cycleStatusBar] {
            XCTAssertTrue(AppCommandCatalog.paletteCommands.contains(command), "\(command)")
            XCTAssertTrue(AppCommandCatalog.bindableCommands.contains(command), "\(command)")
        }
    }
}
