//
//  SidebarTerminalGlyphsTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `SidebarTerminalGlyphs`: the text
//  glyphs the sidebar's terminal style draws in place of SF Symbols and
//  `Circle()` shapes, so its rows sit on the terminal font's character grid
//  the way herdr's own sidebar does (▾/▸ tree disclosure, ○ for a workspace
//  with a known agent status, · for one without, ● trailing a session row).

import XCTest
@testable import Vakta

final class SidebarTerminalGlyphsTests: XCTestCase {
    func test_disclosure_isADownTriangleWhenExpanded_andRightTriangleWhenCollapsed() {
        XCTAssertEqual(SidebarTerminalGlyphs.disclosure(expanded: true), "▾")
        XCTAssertEqual(SidebarTerminalGlyphs.disclosure(expanded: false), "▸")
    }

    func test_workspaceStatus_isAHollowCircleForEveryLiveAgentStatus() {
        // Color (see `sidebarStatusColor`), not shape, tells these apart --
        // matching herdr, which draws one ○ and recolors it.
        for status in [AgentStatus.working, .attention, .idle] {
            XCTAssertEqual(SidebarTerminalGlyphs.workspaceStatus(status), "○", "\(status)")
        }
    }

    func test_workspaceStatus_done_isACheckmark() {
        // A real completion keeps reading differently from merely idle --
        // the same distinction `sidebarStatusIsCheckmark` draws elsewhere.
        XCTAssertEqual(SidebarTerminalGlyphs.workspaceStatus(.done), "✓")
    }

    func test_workspaceStatus_withNoKnownAgent_isAMutedMiddleDot() {
        // Never blank: every workspace row keeps a glyph in the status
        // column so labels stay aligned on the grid.
        XCTAssertEqual(SidebarTerminalGlyphs.workspaceStatus(.none), "·")
        XCTAssertEqual(SidebarTerminalGlyphs.workspaceStatus(.unavailable), "·")
    }

    func test_sessionStatus_isAFilledCircleForEveryLiveAgentStatus() {
        for status in [AgentStatus.working, .attention, .idle] {
            XCTAssertEqual(SidebarTerminalGlyphs.sessionStatus(status), "●", "\(status)")
        }
    }

    func test_sessionStatus_done_isACheckmark() {
        XCTAssertEqual(SidebarTerminalGlyphs.sessionStatus(.done), "✓")
    }

    func test_sessionStatus_withNoKnownAgent_drawsNothing() {
        // A plain shell/tmux session has no agent to report on; its row's
        // trailing edge stays empty rather than showing a meaningless dot.
        XCTAssertNil(SidebarTerminalGlyphs.sessionStatus(.none))
        XCTAssertNil(SidebarTerminalGlyphs.sessionStatus(.unavailable))
    }
}
