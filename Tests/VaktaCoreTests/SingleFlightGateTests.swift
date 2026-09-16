//
//  SingleFlightGateTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `SingleFlightGate`.

import XCTest
@testable import Vakta

@MainActor
final class SingleFlightGateTests: XCTestCase {
    func test_beginIfIdle_whenIdle_returnsTrueAndMarksInFlight() {
        let gate = SingleFlightGate()
        XCTAssertTrue(gate.beginIfIdle())
        XCTAssertTrue(gate.isInFlight)
    }

    func test_beginIfIdle_whileInFlight_returnsFalse_repeatedTicksDoNotQueue() {
        let gate = SingleFlightGate()
        XCTAssertTrue(gate.beginIfIdle())
        // Simulates repeated timer ticks arriving before the first query
        // finished -- every one of them must be dropped, not queued.
        XCTAssertFalse(gate.beginIfIdle())
        XCTAssertFalse(gate.beginIfIdle())
        XCTAssertFalse(gate.beginIfIdle())
    }

    func test_end_thenBeginIfIdle_returnsTrueAgain() {
        let gate = SingleFlightGate()
        _ = gate.beginIfIdle()
        gate.end()
        XCTAssertFalse(gate.isInFlight)
        XCTAssertTrue(gate.beginIfIdle())
    }
}
