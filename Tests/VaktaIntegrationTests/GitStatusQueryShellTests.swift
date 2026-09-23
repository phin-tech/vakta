//
//  GitStatusQueryShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the file sidebar's Changes mode against a real `git` in a
//  temporary repository (isolated HOME, no system config) -- never the
//  user's own repositories or git config.
//

import XCTest
@testable import Vakta

final class GitStatusQueryShellTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String]!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStatusQueryShellTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        process.arguments = ["git", "-c", "user.name=Vakta Tests", "-c", "user.email=tests@example.invalid"] + arguments
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

    private func write(_ text: String, to relativePath: String, in base: URL) throws {
        let url = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A committed repo, then: a rename, an edit in `sub/`, a deletion, and
    /// an untracked file nested two levels deep (git reports its untracked
    /// top directory, `u/`, which the query leaves out).
    private func makeDirtyRepository() throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", in: repo)
        try write("a", to: "a.txt", in: repo)
        try write("b", to: "sub/b.txt", in: repo)
        try write("c", to: "c.txt", in: repo)
        try git("add", ".", in: repo)
        try git("commit", "-qm", "initial", in: repo)

        try git("mv", "a.txt", "renamed.txt", in: repo)
        try write("b edited", to: "sub/b.txt", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("c.txt"))
        try write("q", to: "u/v/q.txt", in: repo)
        return repo
    }

    func test_repositoryRoot_reportsModifiedAndNewFiles_only() throws {
        let repo = try makeDirtyRepository()
        try write("n", to: "new.txt", in: repo)

        let outcome = GitStatusQuery.query(root: repo.path, environment: environment)

        guard case .changes(let changes) = outcome else { return XCTFail("expected changes, got \(outcome)") }
        XCTAssertEqual(Set(changes), [
            GitChange(path: "renamed.txt", kind: .renamed),
            GitChange(path: "sub/b.txt", kind: .modified),
            GitChange(path: "new.txt", kind: .untracked),
        ], "the deleted c.txt and the untracked u/ directory are left out")
    }

    func test_subdirectoryRoot_reportsOnlyItsChanges_relativeToIt() throws {
        let repo = try makeDirtyRepository()

        let outcome = GitStatusQuery.query(root: repo.appendingPathComponent("sub").path, environment: environment)

        XCTAssertEqual(outcome, .changes([GitChange(path: "b.txt", kind: .modified)]))
    }

    func test_query_leavesNoIndexLockBehind_andDoesNotRewriteTheIndex() throws {
        let repo = try makeDirtyRepository()
        let index = repo.appendingPathComponent(".git/index")
        // Make the index look stale so a locking `git status` would refresh
        // and rewrite it.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: index.path)
        let before = try Data(contentsOf: index)
        let beforeDate = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date

        _ = GitStatusQuery.query(root: repo.path, environment: environment)

        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date, beforeDate)
    }

    func test_userUntrackedConfig_doesNotChangeWhatIsReported() throws {
        let repo = try makeDirtyRepository()
        try write("n", to: "new.txt", in: repo)
        let expected: Set<GitChange> = [
            GitChange(path: "renamed.txt", kind: .renamed),
            GitChange(path: "sub/b.txt", kind: .modified),
            GitChange(path: "new.txt", kind: .untracked),
        ]

        for mode in ["no", "all"] {
            try git("config", "status.showUntrackedFiles", mode, in: repo)
            guard case .changes(let changes) = GitStatusQuery.query(root: repo.path, environment: environment) else {
                return XCTFail("expected changes with showUntrackedFiles=\(mode)")
            }
            XCTAssertEqual(Set(changes), expected, "showUntrackedFiles=\(mode)")
        }
    }

    func test_symlinkedRoot_reportsTheLinkedDirectorysChanges() throws {
        let repo = try makeDirtyRepository()
        let link = root.appendingPathComponent("link-to-sub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.appendingPathComponent("sub"))

        XCTAssertEqual(
            GitStatusQuery.query(root: link.path, environment: environment),
            .changes([GitChange(path: "b.txt", kind: .modified)])
        )
    }

    func test_linkedWorktree_reportsItsOwnChanges() throws {
        let repo = try makeDirtyRepository()
        let worktree = root.appendingPathComponent("wt", isDirectory: true)
        try git("worktree", "add", "-q", worktree.path, in: repo)
        try write("edited in worktree", to: "sub/b.txt", in: worktree)

        XCTAssertEqual(
            GitStatusQuery.query(root: worktree.path, environment: environment),
            .changes([GitChange(path: "sub/b.txt", kind: .modified)])
        )
    }

    func test_submoduleWithChanges_isOneModifiedEntry() throws {
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try git("init", "-q", in: library)
        try write("v1", to: "lib.txt", in: library)
        try git("add", ".", in: library)
        try git("commit", "-qm", "lib", in: library)

        let app = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try git("init", "-q", in: app)
        try git("-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "vendor/library", in: app)
        try git("commit", "-qm", "add submodule", in: app)
        try write("v2", to: "vendor/library/lib.txt", in: app)

        XCTAssertEqual(
            GitStatusQuery.query(root: app.path, environment: environment),
            .changes([GitChange(path: "vendor/library", kind: .modified)]),
            "the submodule is one row, not its inner files"
        )
    }

    func test_cleanRepository_hasNoChanges() throws {
        let repo = root.appendingPathComponent("clean", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", in: repo)
        try write("x", to: "x.txt", in: repo)
        try git("add", ".", in: repo)
        try git("commit", "-qm", "initial", in: repo)

        XCTAssertEqual(GitStatusQuery.query(root: repo.path, environment: environment), .changes([]))
    }

    func test_plainDirectory_isNotARepository() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        // Stop discovery at the temp root so an enclosing repository (if the
        // temp dir ever lives inside one) can't answer for it.
        var env = environment!
        env["GIT_CEILING_DIRECTORIES"] = root.path

        XCTAssertEqual(GitStatusQuery.query(root: plain.path, environment: env), .notARepository)
    }

    func test_missingGit_isUnavailable() throws {
        let repo = try makeDirtyRepository()
        var env = environment!
        env["PATH"] = root.appendingPathComponent("empty-bin").path

        XCTAssertEqual(GitStatusQuery.query(root: repo.path, environment: env), .unavailable)
    }
}
