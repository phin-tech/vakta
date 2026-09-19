//
//  PaletteQueryTests.swift
//  VaktaCoreTests
//
//  RED coverage for Cmd-K's global pane-search leader.

import XCTest
@testable import Vakta

final class PaletteQueryTests: XCTestCase {
    func test_parse_atLeader_entersGlobalPaneMode() {
        XCTAssertEqual(
            PaletteQuery.parse("@test-123"),
            PaletteQuery(mode: .allPanes, text: "test-123")
        )
    }

    func test_parse_leaderAlone_entersGlobalPaneModeWithEmptyText() {
        XCTAssertEqual(
            PaletteQuery.parse("@"),
            PaletteQuery(mode: .allPanes, text: "")
        )
    }

    func test_parse_normalText_preservesNormalMode() {
        XCTAssertEqual(
            PaletteQuery.parse("guildhall"),
            PaletteQuery(mode: .normal, text: "guildhall")
        )
    }

    func test_parse_doubleLeader_escapesGlobalPaneMode() {
        XCTAssertEqual(
            PaletteQuery.parse("@@test-123"),
            PaletteQuery(mode: .normal, text: "@test-123")
        )
    }
}
