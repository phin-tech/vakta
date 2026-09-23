//
//  StatusBarBehaviorTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the status bar's timing: Auto-hide's Dock-style
//  reveal/hide/peek state machine, Automatic mode's undock hysteresis, and
//  which content changes warrant a peek. Time is supplied, never read.

import XCTest
@testable import Vakta

final class StatusBarBehaviorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: auto-hide

    private func moved(_ state: StatusBarAutoHideState, _ pointer: StatusBarPointer, _ seconds: TimeInterval) -> StatusBarAutoHideState {
        StatusBarAutoHide.pointerMoved(state, to: pointer, at: at(seconds))
    }

    private func ticked(_ state: StatusBarAutoHideState, _ seconds: TimeInterval) -> StatusBarAutoHideState {
        StatusBarAutoHide.tick(state, at: at(seconds))
    }

    func test_dwellInHotZone_reveals() {
        var state = moved(StatusBarAutoHideState(), .hotZone, 0)
        XCTAssertFalse(state.isRevealed)
        XCTAssertEqual(StatusBarAutoHide.nextDeadline(state), at(StatusBarAutoHide.dwell))

        state = ticked(state, StatusBarAutoHide.dwell)
        XCTAssertTrue(state.isRevealed)
    }

    func test_passingThroughQuickly_doesNotReveal() {
        var state = moved(StatusBarAutoHideState(), .hotZone, 0)
        state = moved(state, .outside, 0.1)
        state = ticked(state, 1)

        XCTAssertFalse(state.isRevealed)
        XCTAssertNil(StatusBarAutoHide.nextDeadline(state))
    }

    func test_barRegionWhileHidden_doesNotCountAsHover() {
        let state = ticked(moved(StatusBarAutoHideState(), .bar, 0), 1)
        XCTAssertFalse(state.isRevealed)
    }

    func test_revealed_staysWhileOverBar_andHidesAfterLeaving() {
        var state = ticked(moved(StatusBarAutoHideState(), .hotZone, 0), 0.3)
        state = moved(state, .bar, 0.4)
        state = ticked(state, 10)
        XCTAssertTrue(state.isRevealed, "never hides while the pointer is over it")

        state = moved(state, .outside, 11)
        XCTAssertEqual(StatusBarAutoHide.nextDeadline(state), at(11 + StatusBarAutoHide.hideDelay))
        state = ticked(state, 11 + StatusBarAutoHide.hideDelay - 0.01)
        XCTAssertTrue(state.isRevealed)
        state = ticked(state, 11 + StatusBarAutoHide.hideDelay)
        XCTAssertFalse(state.isRevealed)
    }

    func test_returningBeforeHideDelay_keepsItRevealed() {
        var state = ticked(moved(StatusBarAutoHideState(), .hotZone, 0), 0.3)
        state = moved(state, .outside, 1)
        state = moved(state, .bar, 1.2)
        state = ticked(state, 5)

        XCTAssertTrue(state.isRevealed)
    }

    func test_peek_revealsWithoutHover_thenHides() {
        var state = StatusBarAutoHide.peek(StatusBarAutoHideState(), at: at(0))
        XCTAssertTrue(state.isRevealed)
        XCTAssertEqual(StatusBarAutoHide.nextDeadline(state), at(StatusBarAutoHide.peekDuration))

        state = ticked(state, StatusBarAutoHide.peekDuration)
        XCTAssertFalse(state.isRevealed)
    }

    func test_peek_thenHover_hoverRulesTakeOver() {
        var state = StatusBarAutoHide.peek(StatusBarAutoHideState(), at: at(0))
        state = moved(state, .bar, 1)
        state = ticked(state, StatusBarAutoHide.peekDuration + 5)
        XCTAssertTrue(state.isRevealed)

        state = moved(state, .outside, 20)
        state = ticked(state, 20 + StatusBarAutoHide.hideDelay)
        XCTAssertFalse(state.isRevealed)
    }

    // MARK: summon ("Show Status Bar Briefly")

    func test_summon_revealsForTheSummonDuration() {
        var state = StatusBarAutoHide.toggleSummon(StatusBarAutoHideState(), at: at(0))
        XCTAssertTrue(state.isRevealed)
        XCTAssertEqual(StatusBarAutoHide.nextDeadline(state), at(StatusBarAutoHide.summonDuration))

        state = ticked(state, StatusBarAutoHide.summonDuration - 0.01)
        XCTAssertTrue(state.isRevealed)
        state = ticked(state, StatusBarAutoHide.summonDuration)
        XCTAssertFalse(state.isRevealed)
    }

    func test_summonWhileRevealed_dismissesAtOnce() {
        let summoned = StatusBarAutoHide.toggleSummon(StatusBarAutoHideState(), at: at(0))
        let dismissed = StatusBarAutoHide.toggleSummon(summoned, at: at(5))
        XCTAssertFalse(dismissed.isRevealed)
        XCTAssertNil(StatusBarAutoHide.nextDeadline(dismissed))

        let hovered = ticked(moved(StatusBarAutoHideState(), .hotZone, 0), 1)
        XCTAssertFalse(StatusBarAutoHide.toggleSummon(hovered, at: at(2)).isRevealed, "dismisses a hover reveal too")
    }

    func test_summon_thenHover_staysUntilThePointerLeaves() {
        var state = StatusBarAutoHide.toggleSummon(StatusBarAutoHideState(), at: at(0))
        state = moved(state, .bar, 1)
        state = ticked(state, StatusBarAutoHide.summonDuration + 5)
        XCTAssertTrue(state.isRevealed)
    }

    // MARK: automatic-mode docking

    private func docked(
        _ state: StatusBarDockState,
        wants: Bool,
        _ seconds: TimeInterval,
        visibility: StatusBarVisibility = .auto
    ) -> StatusBarDockState {
        StatusBarDockPlanner.update(state, wantsDock: wants, visibility: visibility, at: at(seconds))
    }

    func test_auto_docksImmediately() {
        XCTAssertTrue(docked(StatusBarDockState(), wants: true, 0).isDocked)
    }

    func test_auto_undocksOnlyAfterContinuousEmptiness() {
        var state = docked(StatusBarDockState(), wants: true, 0)
        state = docked(state, wants: false, 1)
        XCTAssertTrue(state.isDocked)
        XCTAssertEqual(StatusBarDockPlanner.nextDeadline(state), at(1 + StatusBarDockPlanner.undockDelay))

        state = docked(state, wants: true, 5)
        state = docked(state, wants: false, 6)
        state = docked(state, wants: false, 6 + StatusBarDockPlanner.undockDelay - 0.01)
        XCTAssertTrue(state.isDocked, "flapping restarts the wait")

        state = docked(state, wants: false, 6 + StatusBarDockPlanner.undockDelay)
        XCTAssertFalse(state.isDocked)
        XCTAssertNil(StatusBarDockPlanner.nextDeadline(state))
    }

    func test_otherModes_applyImmediately() {
        let dockedState = docked(StatusBarDockState(), wants: true, 0, visibility: .show)
        XCTAssertTrue(dockedState.isDocked)
        XCTAssertFalse(docked(dockedState, wants: false, 0.1, visibility: .hide).isDocked)
        XCTAssertFalse(docked(dockedState, wants: false, 0.1, visibility: .autoHide).isDocked)
    }

    // MARK: peek policy

    private func content(number: Int?, glyph: StatusBarGlyph = .pending, attention: Int = 0) -> StatusBarContent {
        StatusBarContent(
            branch: "b",
            pullRequest: number.map { StatusBarPullRequest(number: $0, url: "u", title: "t", isDraft: false, glyph: glyph) },
            attentionElsewhere: attention
        )
    }

    func test_peek_whenFocusedPullRequestSettlesIntoANewState() {
        XCTAssertTrue(StatusBarPeekPolicy.shouldPeek(from: content(number: 1, glyph: .pending), to: content(number: 1, glyph: .failing)))
        XCTAssertTrue(StatusBarPeekPolicy.shouldPeek(from: content(number: 1, glyph: .failing), to: content(number: 1, glyph: .passing)))
        XCTAssertTrue(StatusBarPeekPolicy.shouldPeek(from: content(number: 1, glyph: .pending), to: content(number: 1, glyph: .changesRequested)))
    }

    func test_noPeek_forPendingSameStateOrADifferentPullRequest() {
        XCTAssertFalse(StatusBarPeekPolicy.shouldPeek(from: content(number: 1, glyph: .passing), to: content(number: 1, glyph: .pending)))
        XCTAssertFalse(StatusBarPeekPolicy.shouldPeek(from: content(number: 1, glyph: .failing), to: content(number: 1, glyph: .failing)))
        XCTAssertFalse(StatusBarPeekPolicy.shouldPeek(from: content(number: 1, glyph: .pending), to: content(number: 2, glyph: .failing)))
        XCTAssertFalse(StatusBarPeekPolicy.shouldPeek(from: nil, to: content(number: 1, glyph: .failing)))
        XCTAssertFalse(StatusBarPeekPolicy.shouldPeek(from: content(number: nil), to: content(number: 1, glyph: .failing)))
    }

    func test_peek_whenMoreOtherPullRequestsNeedAttention() {
        XCTAssertTrue(StatusBarPeekPolicy.shouldPeek(from: content(number: nil, attention: 0), to: content(number: nil, attention: 1)))
        XCTAssertFalse(StatusBarPeekPolicy.shouldPeek(from: content(number: nil, attention: 2), to: content(number: nil, attention: 1)))
    }
}
