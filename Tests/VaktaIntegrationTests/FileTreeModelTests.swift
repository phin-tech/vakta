//
//  FileTreeModelTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the Files tree's loading state: lazy loads off the main
//  actor (a manual scheduler decides when they finish), one-level prefetch,
//  stale-root results dropped, and refresh. Directory contents come from a
//  stateful in-memory filesystem, not the user's disk.
//

import XCTest
@testable import Vakta

private final class ManualScheduler: @unchecked Sendable {
    private var queue: [() -> Void] = []

    var waiting: Int { queue.count }

    func schedule(_ work: @escaping @Sendable () -> Void) { queue.append(work) }

    /// Runs every waiting item, including any queued while running.
    func runAll() {
        while !queue.isEmpty { queue.removeFirst()() }
    }
}

/// Directory contents by path; `nil` for a path that can't be read.
private final class MemoryFileSystem: @unchecked Sendable {
    var directories: [String: [FileEntry]] = [:]

    func children(of path: String) -> [FileEntry]? { directories[path] }
}

@MainActor
final class FileTreeModelTests: XCTestCase {
    private var fs: MemoryFileSystem!
    private var scheduler: ManualScheduler!
    private var model: FileTreeModel!

    override func setUp() async throws {
        fs = MemoryFileSystem()
        fs.directories = [
            "/r": [FileEntry(name: "src", isDirectory: true), FileEntry(name: ".git", isDirectory: true), FileEntry(name: "b.txt", isDirectory: false)],
            "/r/src": [FileEntry(name: "lib", isDirectory: true), FileEntry(name: "main.swift", isDirectory: false)],
            "/r/src/lib": [FileEntry(name: "x.swift", isDirectory: false)],
            "/other": [FileEntry(name: "o.txt", isDirectory: false)],
        ]
        scheduler = ManualScheduler()
        let fs = self.fs!
        model = FileTreeModel(read: { fs.children(of: $0) }, runInBackground: scheduler.schedule)
    }

    /// Runs queued background work and the main-queue hops it posts, until
    /// nothing is left.
    private func settle() {
        repeat {
            scheduler.runAll()
            let drained = expectation(description: "main queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        } while scheduler.waiting > 0
    }

    func test_settingARoot_listsItsChildren_sorted_withoutDotfiles() {
        model.setRoot("/r")
        XCTAssertEqual(model.rows, [], "nothing until the read lands")

        settle()

        XCTAssertEqual(model.rows.map(\.name), ["src", "b.txt"])
        XCTAssertTrue(model.isRootLoaded)
    }

    func test_expandingADirectory_showsItsChildren() {
        model.setRoot("/r")
        settle()

        model.toggle("/r/src")
        settle()

        XCTAssertEqual(model.rows.map(\.path), ["/r/src", "/r/src/lib", "/r/src/main.swift", "/r/b.txt"])
    }

    func test_expandingAPrefetchedDirectory_isImmediate() {
        model.setRoot("/r")
        settle()
        model.toggle("/r/src")
        settle()

        model.toggle("/r/src/lib")

        XCTAssertEqual(model.rows.map(\.path), ["/r/src", "/r/src/lib", "/r/src/lib/x.swift", "/r/src/main.swift", "/r/b.txt"],
                       "lib was read when src opened, so no wait")
    }

    func test_collapsing_hidesChildren_andReexpandingNeedsNoRead() {
        model.setRoot("/r")
        settle()
        model.toggle("/r/src")
        settle()

        model.toggle("/r/src")
        XCTAssertEqual(model.rows.map(\.path), ["/r/src", "/r/b.txt"])
        model.toggle("/r/src")
        XCTAssertEqual(scheduler.waiting, 0)
        XCTAssertEqual(model.rows.map(\.path), ["/r/src", "/r/src/lib", "/r/src/main.swift", "/r/b.txt"])
    }

    func test_resultForAnEarlierRoot_isDropped() {
        model.setRoot("/r")
        model.setRoot("/other")
        settle()

        XCTAssertEqual(model.rows.map(\.path), ["/other/o.txt"])
    }

    func test_changingRoot_forgetsExpansion() {
        model.setRoot("/r")
        settle()
        model.toggle("/r/src")
        settle()

        model.setRoot("/other")
        settle()
        model.setRoot("/r")
        settle()

        XCTAssertEqual(model.rows.map(\.path), ["/r/src", "/r/b.txt"])
    }

    func test_reload_rereadsExpandedDirectories_keepingThemOpen() {
        model.setRoot("/r")
        settle()
        model.toggle("/r/src")
        settle()
        fs.directories["/r/src"]?.append(FileEntry(name: "new.swift", isDirectory: false))
        fs.directories["/r"]?.append(FileEntry(name: "c.txt", isDirectory: false))

        model.reload()
        settle()

        XCTAssertEqual(model.rows.map(\.path), ["/r/src", "/r/src/lib", "/r/src/main.swift", "/r/src/new.swift", "/r/b.txt", "/r/c.txt"])
    }

    func test_unreadableDirectory_expandsEmpty() {
        fs.directories["/r/src"] = nil
        model.setRoot("/r")
        settle()

        model.toggle("/r/src")
        settle()

        XCTAssertEqual(model.rows.map(\.path), ["/r/src", "/r/b.txt"])
        XCTAssertEqual(model.rows.first?.isExpanded, true)
    }

    func test_clearingTheRoot_emptiesTheTree() {
        model.setRoot("/r")
        settle()
        model.setRoot(nil)

        XCTAssertEqual(model.rows, [])
        XCTAssertFalse(model.isRootLoaded)
    }
}
