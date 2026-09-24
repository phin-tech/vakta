//
//  WorkspaceRefreshTriggerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the passthrough-driven workspace refresh: a key
//  or click sent into a workspace-capable session's terminal (tmux prefix+n,
//  a herdr TUI switch, ...) is the only local signal Vakta has that the
//  active workspace/window might have changed underneath it, since tmux has
//  no event stream (docs/multiplexer-backends.md) and herdr's own
//  `workspace.*` events are unverified (docs/herdr-events-plan.md's
//  Follow-ups). Two pure pieces: `WorkspaceRefreshGate.shouldTrigger` decides
//  whether a given event is even a candidate; `WorkspaceRefreshDebouncer`
//  decides *when* a candidate actually fires, collapsing a typing/click
//  burst into one fetch without starving updates during a long burst.

import XCTest
@testable import Vakta

final class WorkspaceRefreshGateTests: XCTestCase {
    func test_allConditionsMet_triggers() {
        XCTAssertTrue(WorkspaceRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: true,
            sessionIsFocused: true,
            supportsWorkspaces: true,
            showWorkspaces: true
        ))
    }

    func test_wrongEventKind_doesNotTrigger() {
        XCTAssertFalse(WorkspaceRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: false,
            sessionIsFocused: true,
            supportsWorkspaces: true,
            showWorkspaces: true
        ))
    }

    func test_sessionNotFocused_doesNotTrigger() {
        XCTAssertFalse(WorkspaceRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: true,
            sessionIsFocused: false,
            supportsWorkspaces: true,
            showWorkspaces: true
        ))
    }

    func test_targetWithoutWorkspaceAnalogue_doesNotTrigger() {
        XCTAssertFalse(WorkspaceRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: true,
            sessionIsFocused: true,
            supportsWorkspaces: false,
            showWorkspaces: true
        ))
    }

    func test_showWorkspacesDisabled_doesNotTrigger() {
        XCTAssertFalse(WorkspaceRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: true,
            sessionIsFocused: true,
            supportsWorkspaces: true,
            showWorkspaces: false
        ))
    }
}

final class FileSidebarRefreshGateTests: XCTestCase {
    func test_allConditionsMet_triggers() {
        XCTAssertTrue(FileSidebarRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: true,
            sessionIsFocused: true,
            fileSidebarVisible: true
        ))
    }

    func test_notVisible_doesNotTrigger() {
        XCTAssertFalse(FileSidebarRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: true,
            sessionIsFocused: true,
            fileSidebarVisible: false
        ))
    }

    func test_wrongEventKind_doesNotTrigger() {
        XCTAssertFalse(FileSidebarRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: false,
            sessionIsFocused: true,
            fileSidebarVisible: true
        ))
    }

    func test_sessionNotFocused_doesNotTrigger() {
        XCTAssertFalse(FileSidebarRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: true,
            sessionIsFocused: false,
            fileSidebarVisible: true
        ))
    }

    // Independent of the workspace disclosure: the file sidebar follows the
    // focused pane even when "Show workspaces" is off (no such input here).
}

final class WorkspaceRefreshDebouncerTests: XCTestCase {
    private let scheduler = WorkspaceRefreshDebouncer(debounceInterval: 0.15, minInterval: 0.5)
    private let epoch = Date(timeIntervalSince1970: 0)

    func test_neverFiredBefore_firesAfterPlainDebounce() {
        let fireDate = scheduler.scheduledFireDate(now: epoch, lastFireDate: nil)
        XCTAssertEqual(fireDate, epoch.addingTimeInterval(0.15))
    }

    func test_lastFireLongAgo_debounceAloneGoverns() {
        let lastFire = epoch.addingTimeInterval(-10)
        let fireDate = scheduler.scheduledFireDate(now: epoch, lastFireDate: lastFire)
        XCTAssertEqual(fireDate, epoch.addingTimeInterval(0.15))
    }

    func test_burstShortlyAfterLastFire_pushedOutToMinIntervalFloor() {
        // Last real fire was 0.1s before "now" -- plain debounce (now+0.15)
        // would land only 0.25s after that fire, under the 0.5s floor, so
        // the floor wins instead.
        let lastFire = epoch.addingTimeInterval(-0.1)
        let fireDate = scheduler.scheduledFireDate(now: epoch, lastFireDate: lastFire)
        XCTAssertEqual(fireDate, lastFire.addingTimeInterval(0.5))
    }

    func test_burstRightAtMinIntervalBoundary_debounceAndFloorAgree() {
        let lastFire = epoch.addingTimeInterval(-0.35)
        // now+0.15 == lastFire+0.5 exactly -- either expression is correct.
        let fireDate = scheduler.scheduledFireDate(now: epoch, lastFireDate: lastFire)
        XCTAssertEqual(fireDate, epoch.addingTimeInterval(0.15))
    }

    // MARK: status bar (switching panes updates the focused PR)

    func test_pullRequestGate_firesOnInputInTheFocusedSessionWhileEnabled() {
        XCTAssertTrue(PullRequestStatusRefreshGate.shouldTrigger(eventIsKeyDownOrLeftMouseDown: true, sessionIsFocused: true, statusBarEnabled: true))
        XCTAssertFalse(PullRequestStatusRefreshGate.shouldTrigger(eventIsKeyDownOrLeftMouseDown: false, sessionIsFocused: true, statusBarEnabled: true))
        XCTAssertFalse(PullRequestStatusRefreshGate.shouldTrigger(eventIsKeyDownOrLeftMouseDown: true, sessionIsFocused: false, statusBarEnabled: true))
        XCTAssertFalse(PullRequestStatusRefreshGate.shouldTrigger(eventIsKeyDownOrLeftMouseDown: true, sessionIsFocused: true, statusBarEnabled: false))
    }
}
