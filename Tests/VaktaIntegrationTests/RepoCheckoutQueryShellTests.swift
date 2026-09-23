//
//  RepoCheckoutQueryShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for resolving a pane's working directory to its checkout
//  against a real `git` in temporary repositories (isolated HOME, no system
//  config) -- never the user's own repositories or git config.

import XCTest
@testable import Vakta

final class RepoCheckoutQueryShellTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String]!

    override func setUpWithError() throws {
        // git reports physical paths; resolve `/var` → `/private/var` up front.
        let temporary = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporary, nil) else { throw XCTSkip("cannot resolve \(temporary)") }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("RepoCheckoutQueryShellTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": home.path,
            "GIT_CONFIG_NOSYSTEM": "1",
        ]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func git(_ arguments: String..., in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Vakta Tests", "-c", "user.email=tests@example.invalid", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("git \(arguments.joined(separator: " ")) exited \(process.terminationStatus); git unavailable?")
        }
    }

    private func makeRepository(commit: Bool = true) throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try git("init", in: repo)
        try git("remote", "add", "origin", "git@github.com:phin-tech/vakta.git", in: repo)
        if commit {
            try Data("x".utf8).write(to: repo.appendingPathComponent("sub/file.txt"))
            try git("add", ".", in: repo)
            try git("commit", "-m", "init", in: repo)
        }
        return repo
    }

    private func query(_ directory: URL) -> RepoCheckout? {
        RepoCheckoutQuery.query(directory: directory.path, environment: environment)
    }

    func test_subdirectory_resolvesRootBranchAndRemotes() throws {
        let repo = try makeRepository()
        try git("config", "branch.main.remote", "origin", in: repo)

        let checkout = try XCTUnwrap(query(repo.appendingPathComponent("sub")))

        XCTAssertEqual(checkout.root, repo.path)
        XCTAssertEqual(checkout.branch, "main")
        XCTAssertEqual(checkout.config["remote.origin.url"], "git@github.com:phin-tech/vakta.git")
        XCTAssertEqual(checkout.config["branch.main.remote"], "origin")
        XCTAssertEqual(
            checkout.pullRequestTarget(supportedHosts: ["github.com"]),
            PullRequestTarget(repository: GitRemote(host: "github.com", owner: "phin-tech", name: "vakta"), branch: "main", headOwner: "phin-tech")
        )
    }

    func test_linkedWorktree_resolvesItsOwnRootAndBranch() throws {
        let repo = try makeRepository()
        let worktree = root.appendingPathComponent("repo-feature", isDirectory: true)
        try git("worktree", "add", "-b", "feature/x", worktree.path, in: repo)

        let checkout = try XCTUnwrap(query(worktree))

        XCTAssertEqual(checkout.root, worktree.path)
        XCTAssertEqual(checkout.branch, "feature/x")
        XCTAssertEqual(checkout.config["remote.origin.url"], "git@github.com:phin-tech/vakta.git")
    }

    func test_detachedHead_hasNoBranch() throws {
        let repo = try makeRepository()
        try git("checkout", "--detach", in: repo)

        let checkout = try XCTUnwrap(query(repo))

        XCTAssertNil(checkout.branch)
    }

    func test_unbornBranch_stillReportsBranch() throws {
        let repo = try makeRepository(commit: false)

        XCTAssertEqual(query(repo)?.branch, "main")
    }

    func test_branchSwitch_isReflectedOnNextQuery() throws {
        let repo = try makeRepository()
        XCTAssertEqual(query(repo)?.branch, "main")

        try git("checkout", "-b", "other", in: repo)

        XCTAssertEqual(query(repo)?.branch, "other")
    }

    func test_plainDirectory_isNotACheckout() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        environment["GIT_CEILING_DIRECTORIES"] = root.path

        XCTAssertNil(query(plain))
    }

    func test_gitNotOnPath_isNotACheckout() throws {
        let repo = try makeRepository()
        environment["PATH"] = root.path

        XCTAssertNil(query(repo))
    }
}
