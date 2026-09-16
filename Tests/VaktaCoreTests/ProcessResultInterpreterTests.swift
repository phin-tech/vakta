//
//  ProcessResultInterpreterTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `ProcessResultInterpreter`: distinct results
//  for every documented failure mode, with no process execution.

import XCTest
@testable import Vakta

final class ProcessResultInterpreterTests: XCTestCase {
    func test_launchFailed_takesPriorityOverEverythingElse() {
        let raw = ProcessRawResult(launchFailed: true, exitCode: 0, stdout: Data("x".utf8), timedOut: true, cancelled: true)
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .launchFailed)
    }

    func test_cancelled_isReportedDistinctlyFromTimeout() {
        let raw = ProcessRawResult(exitCode: nil, cancelled: true)
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .cancelled)
    }

    func test_timedOut_isReportedDistinctlyFromCancellation() {
        let raw = ProcessRawResult(exitCode: nil, timedOut: true)
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .timedOut)
    }

    func test_nonZeroExit_carriesTheExitCode() {
        let raw = ProcessRawResult(exitCode: 7, stdout: Data("x".utf8))
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .nonZeroExit(7))
    }

    func test_missingExitCode_reportsNonZeroExitWithSentinel() {
        // Shouldn't normally happen outside launchFailed/timedOut/cancelled
        // (all handled above), but a nil exit code is never treated as success.
        let raw = ProcessRawResult(exitCode: nil)
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .nonZeroExit(-1))
    }

    func test_invalidUTF8_onZeroExit_isReportedDistinctlyFromSuccess() {
        let raw = ProcessRawResult(exitCode: 0, stdout: Data([0xFF, 0xFE, 0x00]))
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .invalidUTF8)
    }

    func test_zeroExitValidUTF8_isSuccess() {
        let raw = ProcessRawResult(exitCode: 0, stdout: Data("hello".utf8))
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .success("hello"))
    }

    func test_zeroExitEmptyOutput_isSuccessWithEmptyString() {
        let raw = ProcessRawResult(exitCode: 0, stdout: Data())
        XCTAssertEqual(ProcessResultInterpreter.interpret(raw), .success(""))
    }
}
