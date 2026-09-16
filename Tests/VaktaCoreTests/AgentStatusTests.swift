//
//  AgentStatusTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `AgentStatus.init(herdr:)` and `.busiest`:
//  multi-agent summary, including unknown/malformed raw statuses.

import XCTest
@testable import Vakta

final class AgentStatusTests: XCTestCase {
    // MARK: init(herdr:)

    func test_init_knownWorkingSynonyms_mapToWorking() {
        for raw in ["working", "busy", "running", "thinking", "WORKING"] {
            XCTAssertEqual(AgentStatus(herdr: raw), .working, raw)
        }
    }

    func test_init_knownIdleSynonyms_mapToIdle() {
        for raw in ["idle", "ready"] {
            XCTAssertEqual(AgentStatus(herdr: raw), .idle, raw)
        }
    }

    func test_init_knownDoneSynonyms_mapToDone() {
        // Distinct from `.idle`: herdr's "done" means the agent actually
        // completed a task, not merely "never ran"/"reset". Previously
        // folded into `.idle`, which meant a real completion and a
        // never-started session were visually identical.
        for raw in ["done", "complete", "DONE"] {
            XCTAssertEqual(AgentStatus(herdr: raw), .done, raw)
        }
    }

    func test_init_unknownOrMalformedRaw_mapsToAttention() {
        for raw in ["waiting", "needs-input", "error", "", "???", "some-future-status-herdr-adds"] {
            XCTAssertEqual(AgentStatus(herdr: raw), .attention, raw)
        }
    }

    // MARK: busiest

    func test_busiest_mixedWorkingAndAttention_isAttention_notWorking() {
        // The exact bug this issue exists to fix: one agent still working,
        // another waiting -- the session must surface attention, or the
        // waiting agent is hidden behind the busy one.
        XCTAssertEqual(AgentStatus.busiest([.working, .attention]), .attention)
    }

    func test_busiest_mixedIdleAndAttention_isAttention() {
        XCTAssertEqual(AgentStatus.busiest([.idle, .attention]), .attention)
    }

    func test_busiest_allWorking_isWorking() {
        XCTAssertEqual(AgentStatus.busiest([.working, .working]), .working)
    }

    func test_busiest_allIdle_isIdle() {
        XCTAssertEqual(AgentStatus.busiest([.idle, .idle]), .idle)
    }

    func test_busiest_empty_isNone() {
        XCTAssertEqual(AgentStatus.busiest([]), .none)
    }

    func test_busiest_workingAndNone_isWorking() {
        XCTAssertEqual(AgentStatus.busiest([.working, .none]), .working)
    }

    func test_busiest_workingAndDone_isWorking() {
        // A still-working agent outranks a different agent that already
        // finished -- there's still something to wait on.
        XCTAssertEqual(AgentStatus.busiest([.working, .done]), .working)
    }

    func test_busiest_doneAndIdle_isDone() {
        // Done outranks plain idle: "completed a task" is more informative
        // than "never ran".
        XCTAssertEqual(AgentStatus.busiest([.done, .idle]), .done)
    }

    func test_busiest_attentionAndDone_isAttention() {
        XCTAssertEqual(AgentStatus.busiest([.attention, .done]), .attention)
    }
}
