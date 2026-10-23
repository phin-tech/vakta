//
//  KataCLIShellTests.swift
//  KataVaktaTests
//
//  `KataCLI.run` against a fixture `kata` executable. The Extension runs kata
//  for as long as Vakta is open, so every run must give back the descriptors
//  it opened: leaked pipe ends used up the kernel's pipe memory after a few
//  days, shrinking every new pipe on the Mac to 512 bytes.

import XCTest
@testable import KataVakta

final class KataCLIShellTests: XCTestCase {
    private var directory: URL!
    private var savedPATH: String?

    /// `kata` is found on PATH through /usr/bin/env, so a fixture script goes
    /// first on PATH for the length of each test.
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KataCLIShellTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("kata")
        try "#!/bin/sh\necho \"$@\"\necho warning >&2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        savedPATH = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", directory.path + ":" + (savedPATH ?? "/usr/bin:/bin"), 1)
    }

    override func tearDownWithError() throws {
        if let savedPATH { setenv("PATH", savedPATH, 1) } else { unsetenv("PATH") }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Descriptors open in this test process right now.
    private func openDescriptors() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    func test_run_leavesNoDescriptorsOpen_afterManyRuns() throws {
        _ = KataCLI.run(["warm"])   // let Foundation open anything it keeps for good
        let before = try openDescriptors()
        for _ in 0..<50 {
            XCTAssertEqual(KataCLI.run(["list"])?.status, 0)
        }
        XCTAssertLessThanOrEqual(try openDescriptors(), before + 2)
    }

    func test_run_collectsStdoutAndStderr() throws {
        let result = try XCTUnwrap(KataCLI.run(["list", "--json"]))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "list --json\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "warning\n")
    }
}
