//
//  SidebarWorkspaceEmphasisTests.swift
//  VaktaCoreTests
//
//  Pure cases for how strongly a workspace / tmux window row shows that it is
//  the one on screen, in both sidebar styles. Prominent is the selected
//  session's focused workspace; it must be unmistakable next to its siblings.

import XCTest
@testable import Vakta

final class SidebarWorkspaceEmphasisTests: XCTestCase {
    func test_prominent_isAccentFilledMarkedAndStrong() {
        let style = SidebarRowPresentation.workspaceRowStyle(.prominent)
        XCTAssertTrue(style.usesAccentFill)
        XCTAssertGreaterThanOrEqual(style.fillOpacity, 0.2)
        XCTAssertTrue(style.showsMarker)
        XCTAssertEqual(style.labelEmphasis, .strong)
    }

    func test_subtle_isQuietButStillMarkedAsWhereThatSessionWillLand() {
        let style = SidebarRowPresentation.workspaceRowStyle(.subtle)
        XCTAssertFalse(style.usesAccentFill)
        XCTAssertLessThan(style.fillOpacity, 0.1)
        XCTAssertTrue(style.showsMarker)
        XCTAssertEqual(style.labelEmphasis, .normal)
    }

    func test_none_isDimWithNoFillOrMarker() {
        let style = SidebarRowPresentation.workspaceRowStyle(.none)
        XCTAssertEqual(style.fillOpacity, 0)
        XCTAssertFalse(style.showsMarker)
        XCTAssertEqual(style.labelEmphasis, .dim)
    }

    func test_prominentIsStrictlyStrongerThanSubtleThanNone() {
        let none = SidebarRowPresentation.workspaceRowStyle(.none).fillOpacity
        let subtle = SidebarRowPresentation.workspaceRowStyle(.subtle).fillOpacity
        let prominent = SidebarRowPresentation.workspaceRowStyle(.prominent).fillOpacity
        XCTAssertLessThan(none, subtle)
        XCTAssertLessThan(subtle, prominent)
    }

    func test_terminalFocusMarker_isABlockBarWhenProminent_thinWhenSubtle_andNeverBlank() {
        XCTAssertEqual(SidebarTerminalGlyphs.workspaceFocusMarker(.prominent), "▌")
        XCTAssertEqual(SidebarTerminalGlyphs.workspaceFocusMarker(.subtle), "▏")
        XCTAssertEqual(SidebarTerminalGlyphs.workspaceFocusMarker(.none), " ", "the column stays reserved so labels align")
    }
}
