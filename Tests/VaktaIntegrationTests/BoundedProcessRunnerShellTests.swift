//
//  BoundedProcessRunnerShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `BoundedProcessRunner` actually handles the failure
//  modes it claims to, against real fixture subprocesses -- not just that
//  the pure interpreter looks right in isolation (see
//  `ProcessResultInterpreterTests`).

import XCTest
@testable import Vakta

final class BoundedProcessRunnerShellTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedProcessRunnerShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func writeScript(_ name: String, _ contents: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: large output / pipe capacity

    func test_stdoutExceedingPipeCapacity_completesWithoutAFalseTimeout() throws {
        // macOS's default pipe buffer is 64KB; this writes well past that
        // (~123KB) before exiting. Without continuous draining, the child
        // blocks on its own write() once the pipe fills and never reaches
        // `exit 0`, so the old semaphore-then-read design would time out
        // here instead of succeeding.
        let script = try writeScript("large-output.sh", """
        #!/bin/sh
        i=0
        while [ $i -lt 3000 ]; do
            echo "0123456789012345678901234567890123456789"
            i=$((i+1))
        done
        exit 0
        """)

        let result = BoundedProcessRunner.run(
            executable: script.path,
            arguments: [],
            environment: [:],
            timeout: 5
        )

        guard case .success(let output) = result else {
            return XCTFail("expected success, got \(result)")
        }
        // 3000 lines * 41 bytes each ("0123456789...9\n") -- exact and
        // deterministic, and well past the 64KB default pipe buffer.
        XCTAssertEqual(output.utf8.count, 3000 * 41)
    }

    func test_outputBeyondMaxBytes_isTruncatedToExactlyTheBound() throws {
        let script = try writeScript("medium-output.sh", """
        #!/bin/sh
        i=0
        while [ $i -lt 200 ]; do
            echo "0123456789"
            i=$((i+1))
        done
        exit 0
        """)
        // 200 * 11 = 2200 real bytes, well past this deliberately tiny bound.

        let raw = BoundedProcessRunner.runRaw(
            executable: script.path,
            arguments: [],
            environment: [:],
            timeout: 5,
            maxOutputBytes: 1024
        )

        XCTAssertEqual(raw.stdout.count, 1024)
    }

    // MARK: distinct failure modes

    func test_launchFailure_returnsLaunchFailed() {
        let result = BoundedProcessRunner.run(
            executable: tempDirectory.appendingPathComponent("does-not-exist").path,
            arguments: [],
            environment: [:],
            timeout: 2
        )
        XCTAssertEqual(result, .launchFailed)
    }

    func test_nonZeroExit_returnsNonZeroExitWithCode() throws {
        let script = try writeScript("fail.sh", "#!/bin/sh\nexit 7\n")
        let result = BoundedProcessRunner.run(executable: script.path, arguments: [], environment: [:], timeout: 2)
        XCTAssertEqual(result, .nonZeroExit(7))
    }

    func test_invalidUTF8Output_returnsInvalidUTF8() {
        let result = BoundedProcessRunner.run(
            executable: "/usr/bin/printf",
            arguments: ["\\377\\376"],
            environment: [:],
            timeout: 2
        )
        XCTAssertEqual(result, .invalidUTF8)
    }

    func test_timeout_terminatesALongRunningChildAndReturnsTimedOut() throws {
        let script = try writeScript("sleep-long.sh", "#!/bin/sh\nsleep 30\n")
        let start = Date()

        let result = BoundedProcessRunner.run(executable: script.path, arguments: [], environment: [:], timeout: 0.3)

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "must not actually wait out the child's own sleep")
    }

    func test_childIgnoringTermination_isEscalatedToSIGKILL_withBoundedCleanup() throws {
        let script = try writeScript("ignore-term.sh", """
        #!/bin/sh
        trap '' TERM
        sleep 30
        """)
        let start = Date()

        let result = BoundedProcessRunner.run(executable: script.path, arguments: [], environment: [:], timeout: 0.3)

        XCTAssertEqual(result, .timedOut)
        // terminationGracePeriod (1s) after the 0.3s timeout, plus overhead
        // -- well under the child's own 30s sleep, proving SIGKILL
        // escalation actually happened rather than waiting the child out.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func test_cancellation_terminatesTheChildAndReturnsCancelled() throws {
        let script = try writeScript("sleep-long.sh", "#!/bin/sh\nsleep 30\n")
        var checkCount = 0

        let result = BoundedProcessRunner.run(
            executable: script.path,
            arguments: [],
            environment: [:],
            timeout: 10,
            isCancelled: {
                checkCount += 1
                return checkCount > 1
            }
        )

        XCTAssertEqual(result, .cancelled)
    }
}
