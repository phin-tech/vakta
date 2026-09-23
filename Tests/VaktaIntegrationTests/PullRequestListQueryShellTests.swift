//
//  PullRequestListQueryShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the per-repo PR lookup against a fixture `gh` script on a
//  temporary PATH -- never the user's real gh, auth, or network.

import XCTest
@testable import Vakta

final class PullRequestListQueryShellTests: XCTestCase {
    private var root: URL!
    private var bin: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PullRequestListQueryShellTests-\(UUID().uuidString)", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var environment: [String: String] {
        ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path, "OUT": root.path]
    }

    private func installGh(_ body: String) throws {
        let url = bin.appendingPathComponent("gh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func recordedArguments() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("argv"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }

    func test_query_success_parsesPullRequestsAndPassesExplicitRepository() throws {
        try installGh("""
        : > "$OUT/argv"
        for a in "$@"; do printf '%s\\n' "$a" >> "$OUT/argv"; done
        printf '%s' '[{"headRefName":"feature","headRepositoryOwner":{"login":"phin-tech"},"number":12,"url":"https://github.com/phin-tech/vakta/pull/12","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}]'
        """)

        let outcome = PullRequestListQuery.query(repository: "phin-tech/vakta", environment: environment, limit: 100, timeout: 5)

        guard case .pullRequests(let index) = outcome else { return XCTFail("expected pull requests, got \(outcome)") }
        XCTAssertEqual(index.pullRequest(branch: "feature", headOwner: "phin-tech")?.checks.state, .failing)
        XCTAssertEqual(try recordedArguments(), Array(PullRequestListQuery.arguments(repository: "phin-tech/vakta", limit: 100).dropFirst()))
    }

    func test_query_authenticationRequired_isNotAuthenticated() throws {
        try installGh("echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")

        XCTAssertEqual(
            PullRequestListQuery.query(repository: "o/r", environment: environment, limit: 100, timeout: 5),
            .notAuthenticated
        )
    }

    func test_query_ghNotOnPath_isUnavailable() {
        XCTAssertEqual(
            PullRequestListQuery.query(repository: "o/r", environment: environment, limit: 100, timeout: 5),
            .ghUnavailable
        )
    }

    func test_query_networkFailure_isFailed() throws {
        try installGh("echo 'error connecting to api.github.com' >&2; exit 1")

        XCTAssertEqual(
            PullRequestListQuery.query(repository: "o/r", environment: environment, limit: 100, timeout: 5),
            .failed
        )
    }

    func test_query_hangingGh_isBoundedByTimeout() throws {
        try installGh("exec sleep 30")
        let started = Date()

        XCTAssertEqual(
            PullRequestListQuery.query(repository: "o/r", environment: environment, limit: 100, timeout: 0.5),
            .failed
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
