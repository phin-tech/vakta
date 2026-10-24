//
//  TerminalSearchTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for scrollback search (libghostty-spm 2.2's
//  `TerminalSurfaceSearchDelegate`) and for mirroring the surface's reported
//  font size in the sidebar.

import XCTest
@testable import Vakta

final class TerminalSearchTests: XCTestCase {
    private let idle = TerminalSearchState()

    // MARK: State transitions

    func test_startingASearch_activatesItWithTheSeedNeedle() {
        let state = idle.applying(.started(needle: "error"))
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.needle, "error")
    }

    func test_startingWithNoSeed_keepsThePreviousNeedle() {
        let state = idle.applying(.started(needle: "foo")).applying(.ended).applying(.started(needle: nil))
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.needle, "foo")
    }

    func test_ending_deactivatesAndClearsTheCounts() {
        let state = idle.applying(.started(needle: "x")).applying(.totalUpdated(4)).applying(.selectedUpdated(2))
            .applying(.ended)
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.total)
        XCTAssertNil(state.selected)
    }

    func test_countsUpdateIndependently_andNilMeansUnknown() {
        var state = idle.applying(.started(needle: "x")).applying(.totalUpdated(9)).applying(.selectedUpdated(3))
        XCTAssertEqual(state.total, 9)
        XCTAssertEqual(state.selected, 3)
        state = state.applying(.selectedUpdated(nil))
        XCTAssertEqual(state.total, 9)
        XCTAssertNil(state.selected)
    }

    func test_editingTheNeedle_dropsStaleCountsUntilTheCoreReportsAgain() {
        let state = idle.applying(.started(needle: "a")).applying(.totalUpdated(5)).applying(.selectedUpdated(1))
            .applying(.needleEdited("ab"))
        XCTAssertEqual(state.needle, "ab")
        XCTAssertNil(state.total)
        XCTAssertNil(state.selected)
    }

    func test_countsArriveingWhileInactive_areIgnored() {
        let state = idle.applying(.totalUpdated(7)).applying(.selectedUpdated(1))
        XCTAssertNil(state.total)
        XCTAssertNil(state.selected)
    }

    // MARK: Summary text

    func test_summary_isEmptyForAnEmptyNeedle() {
        XCTAssertEqual(idle.applying(.started(needle: "")).summary, "")
    }

    func test_summary_isEmptyWhileTheCountIsUnknown() {
        XCTAssertEqual(idle.applying(.started(needle: "x")).summary, "")
    }

    func test_summary_reportsNoResultsForZeroMatches() {
        XCTAssertEqual(idle.applying(.started(needle: "x")).applying(.totalUpdated(0)).summary, "No results")
    }

    func test_summary_isOneBasedSelectedOverTotal() {
        // The core's selected index is zero-based.
        let state = idle.applying(.started(needle: "x")).applying(.totalUpdated(12)).applying(.selectedUpdated(2))
        XCTAssertEqual(state.summary, "3/12")
    }

    func test_summary_showsOnlyTheTotalWhenNothingIsSelected() {
        XCTAssertEqual(idle.applying(.started(needle: "x")).applying(.totalUpdated(12)).summary, "12")
    }

    // MARK: Binding actions handed to libghostty

    func test_bindingActions_matchGhosttysActionNames() {
        XCTAssertEqual(TerminalSearchBindingAction.search("needle"), "search:needle")
        XCTAssertEqual(TerminalSearchBindingAction.next, "navigate_search:next")
        XCTAssertEqual(TerminalSearchBindingAction.previous, "navigate_search:previous")
        XCTAssertEqual(TerminalSearchBindingAction.end, "end_search")
    }

    func test_searchAction_carriesTheNeedleVerbatim() {
        XCTAssertEqual(TerminalSearchBindingAction.search("a b:c"), "search:a b:c")
        XCTAssertEqual(TerminalSearchBindingAction.search(""), "search:")
    }

    // MARK: Reported font size

    func test_reportedSize_winsOverTheConfiguredOne() {
        // ⌘+ changes the surface's size without touching terminal.json.
        XCTAssertEqual(SidebarRowFontResolver.terminalSize(reported: 17, configured: 13), 17)
    }

    func test_noReport_fallsBackToTheConfiguredSize() {
        XCTAssertEqual(SidebarRowFontResolver.terminalSize(reported: nil, configured: 14), 14)
    }

    func test_unusableReport_fallsBackToTheConfiguredSize() {
        XCTAssertEqual(SidebarRowFontResolver.terminalSize(reported: .nan, configured: 14), 14)
        XCTAssertEqual(SidebarRowFontResolver.terminalSize(reported: 0, configured: 14), 14)
        XCTAssertEqual(SidebarRowFontResolver.terminalSize(reported: 9999, configured: 14), 14)
    }

    func test_neitherUsable_yieldsTheDefaultSentinelZero() {
        XCTAssertEqual(SidebarRowFontResolver.terminalSize(reported: nil, configured: 0), 0)
    }
}
