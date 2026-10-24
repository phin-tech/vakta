//
//  TerminalSearchModelTests.swift
//  VaktaIntegrationTests
//
//  `TerminalSearchModel` driven through the same delegate calls libghostty
//  makes, with the outgoing binding actions collected as data.

import XCTest
@testable import Vakta

@MainActor
final class TerminalSearchModelTests: XCTestCase {
    private var sent: [String] = []

    private func makeModel() -> TerminalSearchModel {
        sent = []
        let model = TerminalSearchModel()
        model.send = { [unowned self] in self.sent.append($0) }
        return model
    }

    func test_coreReports_showUpInTheSummary() {
        let model = makeModel()
        model.terminalDidStartSearch(needle: "error")
        model.terminalDidUpdateSearchTotal(5)
        model.terminalDidUpdateSearchSelected(0)
        XCTAssertTrue(model.state.isActive)
        XCTAssertEqual(model.state.needle, "error")
        XCTAssertEqual(model.state.summary, "1/5")
    }

    func test_typing_sendsTheSearchAndDropsStaleCounts() {
        let model = makeModel()
        model.terminalDidStartSearch(needle: "a")
        model.terminalDidUpdateSearchTotal(5)
        model.edit("ab")
        XCTAssertEqual(sent, ["search:ab"])
        XCTAssertEqual(model.state.summary, "")
        model.terminalDidUpdateSearchTotal(2)
        XCTAssertEqual(model.state.summary, "2")
    }

    func test_stepping_sendsNavigateActions() {
        let model = makeModel()
        model.terminalDidStartSearch(needle: "a")
        model.next()
        model.previous()
        XCTAssertEqual(sent, ["navigate_search:next", "navigate_search:previous"])
    }

    func test_closing_endsTheSearchAtOnceAndTellsTheCore() {
        let model = makeModel()
        model.terminalDidStartSearch(needle: "a")
        model.terminalDidUpdateSearchTotal(3)
        model.close()
        XCTAssertFalse(model.state.isActive)
        XCTAssertNil(model.state.total)
        XCTAssertEqual(sent, ["end_search"])
    }

    func test_coreEndingTheSearch_deactivatesWithoutSendingAnything() {
        let model = makeModel()
        model.terminalDidStartSearch(needle: "a")
        model.terminalDidEndSearch()
        XCTAssertFalse(model.state.isActive)
        XCTAssertTrue(sent.isEmpty)
    }

    func test_reopening_keepsThePreviousNeedleWhenTheCoreSeedsNone() {
        let model = makeModel()
        model.terminalDidStartSearch(needle: "foo")
        model.terminalDidEndSearch()
        model.terminalDidStartSearch(needle: nil)
        XCTAssertEqual(model.state.needle, "foo")
    }
}
