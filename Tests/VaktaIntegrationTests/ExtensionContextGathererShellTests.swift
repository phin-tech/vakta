//
//  ExtensionContextGathererShellTests.swift
//  VaktaIntegrationTests
//
//  Extension Contexts against a real git repository (plain-shell Sessions,
//  so no multiplexer server is needed).

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class ExtensionContextGathererShellTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionContextGathererShellTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func git(_ arguments: String..., in repo: URL) throws {
        let result = BoundedProcessRunner.run(
            executable: "/usr/bin/env", arguments: ["git", "-C", repo.path] + arguments,
            environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": directory.path], timeout: 10
        )
        guard case .success = result else { throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(arguments): \(result)"]) }
    }

    private func input(cwd: String, focused: Bool) -> ExtensionSessionInput {
        ExtensionSessionInput(
            sessionID: UUID(), target: nil, sessionName: "zsh",
            terminalReportedWorkingDirectory: cwd, profileWorkingDirectory: nil,
            focusedWorkspace: nil, focused: focused
        )
    }

    func test_gather_resolvesGitRootAndBranch_perSession_inOrder() throws {
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let sources = repo.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "3kav-extensions", in: repo)
        let plain = directory.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let contexts = ExtensionContextGatherer.gather(
            [input(cwd: sources.path, focused: true), input(cwd: plain.path, focused: false)],
            path: "/usr/bin:/bin:/opt/homebrew/bin"
        )

        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts.first?.cwd, sources.path)
        // git reports the real path (/private/var/…); compare resolved forms.
        XCTAssertEqual(contexts.first?.gitRoot.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, repo.path)
        XCTAssertEqual(contexts.first?.branch, "3kav-extensions")
        XCTAssertEqual(contexts.first?.focused, true)
        XCTAssertEqual(contexts.last?.cwd, plain.path)
        XCTAssertNil(contexts.last?.gitRoot)
        XCTAssertEqual(contexts.last?.focused, false)
    }
}
