//
//  ToolRunShellTests.swift
//  VaktaGitHubTests
//
//  `Tool.run` against real child processes. The Extension runs git and gh for
//  as long as Vakta is open, so every run must give back the descriptors it
//  opened: leaked pipe ends used up the kernel's pipe memory after a few days,
//  shrinking every new pipe on the Mac to 512 bytes and hanging xcodebuild.

import XCTest
@testable import VaktaGitHub

final class ToolRunShellTests: XCTestCase {
    /// Descriptors open in this test process right now.
    private func openDescriptors() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    func test_run_withoutStdin_leavesNoDescriptorsOpen_afterManyRuns() throws {
        _ = Tool.run(["true"])   // let Foundation open anything it keeps for good
        let before = try openDescriptors()
        for _ in 0..<50 {
            XCTAssertEqual(Tool.run(["true"])?.status, 0)
        }
        XCTAssertLessThanOrEqual(try openDescriptors(), before + 2)
    }

    func test_run_withStdin_leavesNoDescriptorsOpen_afterManyRuns() throws {
        _ = Tool.run(["cat"], stdin: Data("warm".utf8))
        let before = try openDescriptors()
        for _ in 0..<50 {
            XCTAssertEqual(Tool.run(["cat"], stdin: Data("x".utf8))?.status, 0)
        }
        XCTAssertLessThanOrEqual(try openDescriptors(), before + 2)
    }

    func test_run_passesStdinThrough_andCollectsStdoutAndStderr() throws {
        let piped = try XCTUnwrap(Tool.run(["cat"], stdin: Data("hello".utf8)))
        XCTAssertEqual(String(decoding: piped.stdout, as: UTF8.self), "hello")

        let both = try XCTUnwrap(Tool.run(["sh", "-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertEqual(both.status, 3)
        XCTAssertEqual(String(decoding: both.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: both.stderr, as: UTF8.self), "err\n")
    }
}
