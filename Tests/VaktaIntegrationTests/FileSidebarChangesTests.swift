//
//  FileSidebarChangesTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the file sidebar's Changes mode state: the loader's
//  stale-completion guard (driven by a controllable background scheduler and
//  canned query results -- no git), and the persisted mode surviving a
//  restart in `FileSidebarPreferencesStore`.
//

import XCTest
@testable import Vakta

/// Holds background work until the test runs it, so completion order is
/// chosen by the test instead of the thread scheduler. `waiting` is the
/// fake's current state: work handed over and not yet run.
private final class ManualScheduler: @unchecked Sendable {
    private var queue: [() -> Void] = []

    var waiting: Int { queue.count }

    func schedule(_ work: @escaping @Sendable () -> Void) { queue.append(work) }

    /// Runs the oldest waiting work item.
    func runNext() { queue.removeFirst()() }
}

@MainActor
final class FileSidebarChangesLoaderTests: XCTestCase {
    private func outcome(_ path: String) -> GitChangesOutcome {
        .changes([GitChange(path: path, kind: .modified)])
    }

    /// Lets every `DispatchQueue.main.async` hop already enqueued run.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_requestsWhileAQueryIsRunning_runOneFollowUp_forTheLatestRoot() {
        let scheduler = ManualScheduler()
        let loader = FileSidebarChangesLoader(
            query: { root, _ in .changes([GitChange(path: root + ".txt", kind: .modified)]) },
            runInBackground: scheduler.schedule
        )

        loader.load(root: "/a")
        loader.load(root: "/b")
        loader.load(root: "/c")
        XCTAssertEqual(scheduler.waiting, 1, "at most one git run in flight")

        scheduler.runNext()
        drainMainQueue()
        XCTAssertNil(loader.snapshot, "the /a result is not shown under /c")
        XCTAssertEqual(scheduler.waiting, 1, "one follow-up, not one per request")

        scheduler.runNext()
        drainMainQueue()
        XCTAssertEqual(loader.snapshot, GitChangesSnapshot(root: "/c", outcome: outcome("/c.txt")))
        XCTAssertEqual(scheduler.waiting, 0, "nothing left owed")
    }

    func test_sustainedSameRootRefreshes_stillPublishEachResult() {
        // Typing keeps asking for the same root faster than git answers; each
        // answer must still appear rather than being superseded forever.
        let scheduler = ManualScheduler()
        var answer = 0
        let loader = FileSidebarChangesLoader(
            query: { _, _ in answer += 1; return .changes([GitChange(path: "v\(answer)", kind: .modified)]) },
            runInBackground: scheduler.schedule
        )

        loader.load(root: "/a")
        for expected in 1...3 {
            loader.load(root: "/a")
            scheduler.runNext()
            drainMainQueue()
            XCTAssertEqual(loader.snapshot, GitChangesSnapshot(root: "/a", outcome: outcome("v\(expected)")))
        }
    }

    func test_newRootAfterClearing_startsAgain() {
        let scheduler = ManualScheduler()
        let loader = FileSidebarChangesLoader(query: { root, _ in .changes([GitChange(path: root, kind: .modified)]) }, runInBackground: scheduler.schedule)

        loader.load(root: "/a")
        loader.load(root: nil)
        loader.load(root: "/b")
        scheduler.runNext()
        drainMainQueue()
        XCTAssertNil(loader.snapshot, "the cleared /a result stays hidden")
        scheduler.runNext()
        drainMainQueue()
        XCTAssertEqual(loader.snapshot, GitChangesSnapshot(root: "/b", outcome: outcome("/b")))
    }

    func test_snapshot_carriesTheTreeBuiltFromItsChanges() {
        let changes = [GitChange(path: "src/a.swift", kind: .modified), GitChange(path: "build/", kind: .untracked)]
        let snapshot = GitChangesSnapshot(root: "/a", outcome: .changes(changes))
        XCTAssertEqual(snapshot.tree, GitChangeTree.build(changes))
        XCTAssertEqual(GitChangesSnapshot(root: "/a", outcome: .notARepository).tree, [])
    }

    func test_loadingNil_clearsTheSnapshot_andDropsTheInFlightResult() {
        let scheduler = ManualScheduler()
        let loader = FileSidebarChangesLoader(query: { _, _ in .changes([]) }, runInBackground: scheduler.schedule)

        loader.load(root: "/a")
        scheduler.runNext()
        drainMainQueue()
        loader.load(root: "/a")
        loader.load(root: nil)
        scheduler.runNext()
        drainMainQueue()

        XCTAssertNil(loader.snapshot)
        XCTAssertEqual(scheduler.waiting, 0, "a cleared request owes no follow-up")
    }

    func test_reloadingTheSameRoot_keepsThePreviousSnapshotUntilTheNewResultLands() {
        let scheduler = ManualScheduler()
        var next = outcome("first")
        let loader = FileSidebarChangesLoader(query: { _, _ in next }, runInBackground: scheduler.schedule)

        loader.load(root: "/a")
        scheduler.runNext()
        drainMainQueue()
        next = outcome("second")
        loader.load(root: "/a")

        XCTAssertEqual(loader.snapshot, GitChangesSnapshot(root: "/a", outcome: outcome("first")), "no flash of empty while refreshing")

        scheduler.runNext()
        drainMainQueue()
        XCTAssertEqual(loader.snapshot, GitChangesSnapshot(root: "/a", outcome: outcome("second")))
    }
}

final class FileSidebarModePersistenceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSidebarModePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    @MainActor
    func test_mode_persistsAcrossARestart() {
        let store = FileSidebarPreferencesStore(root: tempDirectory)
        XCTAssertEqual(store.mode, .files)
        store.mode = .changes

        XCTAssertEqual(FileSidebarPreferencesStore(root: tempDirectory).mode, .changes)
    }

    @MainActor
    func test_fileFromBeforeMode_loadsAsFiles_andKeepsItsOtherValuesOnTheNextSave() throws {
        let fileURL = FileSidebarPreferencesPersistence.store(root: tempDirectory).fileURL
        try Data(#"{"isVisible": true, "width": 333}"#.utf8).write(to: fileURL)

        let store = FileSidebarPreferencesStore(root: tempDirectory)
        XCTAssertEqual(store.mode, .files)
        store.mode = .changes

        guard case .loaded(let saved) = FileSidebarPreferencesPersistence.load(root: tempDirectory) else {
            return XCTFail("expected the saved file to load")
        }
        XCTAssertEqual(saved, FileSidebarPreferences(isVisible: true, width: 333, mode: .changes))
    }

    @MainActor
    func test_applyingAPlannedChange_updatesVisibilityAndModeTogether() {
        let store = FileSidebarPreferencesStore(root: tempDirectory)

        store.apply(FileSidebarModePlanner.togglingChanges(store.preferences))

        XCTAssertTrue(store.isVisible)
        XCTAssertEqual(store.mode, .changes)
        guard case .loaded(let saved) = FileSidebarPreferencesPersistence.load(root: tempDirectory) else {
            return XCTFail("expected the saved file to load")
        }
        XCTAssertEqual(saved.mode, .changes)
        XCTAssertTrue(saved.isVisible)
    }
}
