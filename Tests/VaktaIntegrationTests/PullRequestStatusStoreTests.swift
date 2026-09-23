//
//  PullRequestStatusStoreTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `PullRequestStatusStore` against a stateful in-memory
//  world (panes, checkouts, and gh answers the test changes between cycles),
//  a manual background scheduler, and a controllable clock. Assertions are
//  on published state only.

import XCTest
@testable import Vakta

/// Holds background work until the test runs it, so completion order is
/// chosen by the test instead of the thread scheduler.
private final class ManualScheduler: @unchecked Sendable {
    private var queue: [() -> Void] = []

    var waiting: Int { queue.count }

    func schedule(_ work: @escaping @Sendable () -> Void) { queue.append(work) }

    func runNext() { queue.removeFirst()() }
}

/// The multiplexer, git, and GitHub state the store observes. Tests mutate
/// it between cycles; the store only reads it through its helper closures.
private final class FakeWorld: @unchecked Sendable {
    private let lock = NSLock()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    private var _panes: [UUID: [Pane]] = [:]
    private var _checkouts: [String: RepoCheckout] = [:]
    private var _pullRequests: [GitRemote: PullRequestListOutcome] = [:]

    var panes: [UUID: [Pane]] {
        get { locked { _panes } }
        set { locked { _panes = newValue } }
    }
    var checkouts: [String: RepoCheckout] {
        get { locked { _checkouts } }
        set { locked { _checkouts = newValue } }
    }
    var pullRequests: [GitRemote: PullRequestListOutcome] {
        get { locked { _pullRequests } }
        set { locked { _pullRequests = newValue } }
    }
}

@MainActor
final class PullRequestStatusStoreTests: XCTestCase {
    private let repository = GitRemote(host: "github.com", owner: "o", name: "r")
    private let other = GitRemote(host: "github.com", owner: "o", name: "other")
    private let sessionID = UUID()
    private let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])

    private var world: FakeWorld!
    private var scheduler: ManualScheduler!
    private var clock: Date!
    private var store: PullRequestStatusStore!

    override func setUp() {
        world = FakeWorld()
        scheduler = ManualScheduler()
        clock = Date(timeIntervalSince1970: 50_000)
        let world = world!
        store = PullRequestStatusStore(
            listPanes: { session, _ in world.panes[session.id] },
            resolveCheckout: { directory, _ in world.checkouts[directory] },
            listPullRequests: { repository, _ in world.pullRequests[repository] ?? .failed },
            now: { [unowned self] in self.clock },
            runInBackground: { [scheduler] in scheduler!.schedule($0) },
            policy: PullRequestRefreshPolicy(focusedMaxAge: 60, backgroundMaxAge: 300),
            checkoutMaxAge: 60
        )
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    /// Requests a refresh and runs the resulting cycle to completion.
    private func cycle(sessions: [UUID]? = nil, forceFocused: Bool = false) {
        store.refresh(sessions: snapshots(sessions ?? [sessionID]), focusedSessionID: sessionID, forceFocused: forceFocused)
        scheduler.runNext()
        drainMainQueue()
    }

    private func snapshots(_ ids: [UUID]) -> [PullRequestSessionSnapshot] {
        ids.map { PullRequestSessionSnapshot(id: $0, sessionName: "s", target: target) }
    }

    private func pane(_ id: String, _ directory: String, focused: Bool = false, workspace: String = "w1") -> Pane {
        Pane(id: id, tabID: "t", label: id, focused: focused, status: .none, workspaceID: workspace, workingDirectory: directory)
    }

    private func checkout(_ root: String, _ branch: String, remote: GitRemote? = nil) -> RepoCheckout {
        let remote = remote ?? repository
        return RepoCheckout(root: root, branch: branch, config: ["remote.origin.url": "git@github.com:\(remote.owner)/\(remote.name).git"])
    }

    private func pr(_ number: Int, branch: String, failing: Int = 0) -> PullRequestStatus {
        PullRequestStatus(
            number: number,
            url: "https://github.com/o/r/pull/\(number)",
            title: "PR \(number)",
            isDraft: false,
            headBranch: branch,
            headOwner: "o",
            checks: PullRequestChecks(passing: failing == 0 ? 1 : 0, failing: failing, pending: 0),
            review: nil
        )
    }

    private func serve(_ pullRequests: [PullRequestStatus], for remote: GitRemote? = nil) {
        world.pullRequests[remote ?? repository] = .pullRequests(PullRequestIndex(pullRequests: pullRequests, isComplete: true))
    }

    private func setUpTwoPanesOnOneBranch() {
        world.panes[sessionID] = [pane("p1", "/r", focused: true), pane("p2", "/r/sub")]
        world.checkouts = ["/r": checkout("/r", "feature"), "/r/sub": checkout("/r", "feature")]
        serve([pr(7, branch: "feature", failing: 1)])
    }

    // MARK: publishing

    func test_publishesFocusedPullRequestAndWorkspaceSummary() {
        setUpTwoPanesOnOneBranch()

        cycle()

        XCTAssertEqual(store.focused[sessionID]?.target.branch, "feature")
        XCTAssertEqual(store.focused[sessionID]?.pullRequest?.number, 7)
        XCTAssertEqual(store.workspaceSummaries[sessionID]?["w1"], PullRequestSummary(pullRequestCount: 1, failingChecks: 1, changesRequested: 0))
    }

    func test_focusedPaneWithoutPullRequest_publishesBranchOnly() {
        world.panes[sessionID] = [pane("p1", "/r", focused: true)]
        world.checkouts = ["/r": checkout("/r", "main")]
        serve([])

        cycle()

        XCTAssertEqual(store.focused[sessionID], FocusedPullRequestState(
            target: PullRequestTarget(repository: repository, branch: "main", headOwner: "o"),
            pullRequest: nil
        ))
        XCTAssertNil(store.workspaceSummaries[sessionID]?["w1"])
    }

    func test_nonRepositoryPanes_publishNothing() {
        world.panes[sessionID] = [pane("p1", "/plain", focused: true)]

        cycle()

        XCTAssertNil(store.focused[sessionID])
        XCTAssertEqual(store.workspaceSummaries[sessionID] ?? [:], [:])
    }

    // MARK: staleness and failure

    func test_sessionClosedWhileCycleInFlight_leavesNoEntry() {
        setUpTwoPanesOnOneBranch()
        store.refresh(sessions: snapshots([sessionID]), focusedSessionID: sessionID, forceFocused: false)

        // The session closes before the in-flight cycle's result lands.
        store.refresh(sessions: [], focusedSessionID: nil, forceFocused: false)
        scheduler.runNext()
        drainMainQueue()

        XCTAssertNil(store.focused[sessionID])
        XCTAssertNil(store.workspaceSummaries[sessionID])
    }

    func test_failingFetch_keepsPreviousStatusVisible() {
        setUpTwoPanesOnOneBranch()
        cycle()

        world.pullRequests[repository] = .failed
        clock = clock.addingTimeInterval(61)
        cycle()

        XCTAssertEqual(store.focused[sessionID]?.pullRequest?.number, 7)
    }

    func test_withinFocusedTTL_keepsCachedData_forceFocusedRefreshesImmediately() {
        setUpTwoPanesOnOneBranch()
        cycle()
        serve([pr(7, branch: "feature", failing: 0)])
        clock = clock.addingTimeInterval(10)

        cycle()
        XCTAssertEqual(store.focused[sessionID]?.pullRequest?.checks.state, .failing, "fresh cache is not refetched")

        cycle(forceFocused: true)
        XCTAssertEqual(store.focused[sessionID]?.pullRequest?.checks.state, .passing)
    }

    func test_focusedRepositoryRefreshesAfterTTL() {
        setUpTwoPanesOnOneBranch()
        cycle()
        serve([pr(7, branch: "feature", failing: 0)])
        clock = clock.addingTimeInterval(60)

        cycle()

        XCTAssertEqual(store.focused[sessionID]?.pullRequest?.checks.state, .passing)
    }

    // MARK: pane changes

    func test_paneMovingToAnotherRepository_followsItOnceResolved() {
        setUpTwoPanesOnOneBranch()
        cycle()

        world.panes[sessionID] = [pane("p1", "/other", focused: true)]
        world.checkouts["/other"] = checkout("/other", "topic", remote: other)
        serve([pr(3, branch: "topic")], for: other)
        cycle()

        XCTAssertEqual(store.focused[sessionID]?.target.repository, other)
        XCTAssertEqual(store.focused[sessionID]?.pullRequest?.number, 3)
    }

    func test_requestsDuringCycle_collapseIntoOneFollowUp() {
        setUpTwoPanesOnOneBranch()
        store.refresh(sessions: snapshots([sessionID]), focusedSessionID: sessionID, forceFocused: false)
        store.refresh(sessions: snapshots([sessionID]), focusedSessionID: sessionID, forceFocused: false)
        store.refresh(sessions: snapshots([sessionID]), focusedSessionID: sessionID, forceFocused: true)
        XCTAssertEqual(scheduler.waiting, 1)

        scheduler.runNext()
        drainMainQueue()

        XCTAssertEqual(scheduler.waiting, 1, "one follow-up for the latest request")
        scheduler.runNext()
        drainMainQueue()
        XCTAssertEqual(scheduler.waiting, 0)
        XCTAssertEqual(store.focused[sessionID]?.pullRequest?.number, 7)
    }
}
