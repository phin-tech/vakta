//
//  MultiplexerSetupShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the tour's install step: `ExecutableSearch.locate`
//  against a real temporary directory, and the installer profile's command
//  line run through a real `/bin/sh` with harmless `true`/`false` standing
//  in for the install -- it reports the outcome and exits on Return.
//

import XCTest
@testable import Vakta

final class MultiplexerSetupShellTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiplexerSetupShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, executable: Bool) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    // MARK: locate

    func test_locate_findsAnExecutableFile() throws {
        let tool = try makeFile("herdr", executable: true)
        XCTAssertEqual(ExecutableSearch.locate(named: "herdr", inPATH: "/nonexistent:\(directory.path)"), tool.path)
    }

    func test_locate_ignoresANonExecutableFile() throws {
        _ = try makeFile("tmux", executable: false)
        XCTAssertNil(ExecutableSearch.locate(named: "tmux", inPATH: directory.path))
    }

    func test_locate_ignoresADirectoryWithTheToolsName() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("herdr"), withIntermediateDirectories: false)
        XCTAssertNil(ExecutableSearch.locate(named: "herdr", inPATH: directory.path))
    }

    // MARK: installer script

    /// Runs the profile's command line the way libghostty does (a shell
    /// parsing the whole line), feeding one Return on stdin.
    private func runInstaller(installCommand: String) throws -> (output: String, status: Int32) {
        let profile = MultiplexerSetupPlanner.installerProfile(for: .herdr, installCommand: installCommand, id: UUID())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", profile.resolvedCommand(sessionName: "unused")]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data("\n".utf8))
        try input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if process.isRunning {
            process.terminate()
            XCTFail("installer script did not exit after Return")
        }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (text, process.terminationStatus)
    }

    func test_installerScript_success_reportsInstalled_andExitsOnReturn() throws {
        let result = try runInstaller(installCommand: "true")
        XCTAssertTrue(result.output.contains("herdr is installed"), result.output)
        XCTAssertEqual(result.status, 0)
    }

    func test_installerScript_failure_reportsTheExitStatus() throws {
        let result = try runInstaller(installCommand: "sh -c 'exit 3'")
        XCTAssertTrue(result.output.contains("failed (exit 3)"), result.output)
    }

    func test_installerScript_echoesTheCommandItRuns() throws {
        let result = try runInstaller(installCommand: "true")
        XCTAssertTrue(result.output.contains("$ true"), result.output)
    }
}
