//
//  AttentionTransitionPolicyTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `AttentionTransitionPolicy.decide`.

import XCTest
@testable import Vakta

final class AttentionTransitionPolicyTests: XCTestCase {
    private func decide(
        from: AgentStatus?,
        to: AgentStatus,
        isSelected: Bool = false,
        appActive: Bool = false,
        notifyOnAttention: Bool = true,
        notifyOnFinished: Bool = true,
        bounceDock: Bool = true
    ) -> AttentionDecision {
        AttentionTransitionPolicy.decide(
            from: from,
            to: to,
            isSelected: isSelected,
            appActive: appActive,
            notifyOnAttention: notifyOnAttention,
            notifyOnFinished: notifyOnFinished,
            bounceDock: bounceDock
        )
    }

    // MARK: first observation / focus silence

    func test_firstObservation_isSilent_regardlessOfDestinationStatus() {
        for to: AgentStatus in [.attention, .working, .idle, .none] {
            XCTAssertEqual(decide(from: nil, to: to), .silent, "\(to)")
        }
    }

    func test_selectedAndFrontmost_needsAttention_isSilent() {
        XCTAssertEqual(decide(from: .working, to: .attention, isSelected: true, appActive: true), .silent)
    }

    func test_selectedButAppNotActive_stillNotifies() {
        // Only *selected AND frontmost* counts as "already looking at it."
        let result = decide(from: .working, to: .attention, isSelected: true, appActive: false)
        XCTAssertTrue(result.shouldBanner)
    }

    func test_frontmostButNotSelected_stillNotifies() {
        let result = decide(from: .working, to: .attention, isSelected: false, appActive: true)
        XCTAssertTrue(result.shouldBanner)
    }

    // MARK: needs-attention transition

    func test_toAttention_fromWorking_notifiesAndBounces() {
        let result = decide(from: .working, to: .attention)
        XCTAssertTrue(result.shouldBanner)
        XCTAssertEqual(result.bannerBody, "Needs your attention")
        XCTAssertTrue(result.playSound)
        XCTAssertTrue(result.shouldBounceDock)
    }

    func test_toAttention_fromIdle_notifies() {
        XCTAssertTrue(decide(from: .idle, to: .attention).shouldBanner)
    }

    func test_toAttention_fromAttention_doesNotReNotify_noSpamOnRepeatedIdenticalObservations() {
        let result = decide(from: .attention, to: .attention)
        XCTAssertEqual(result, .silent)
    }

    func test_toAttention_bannerAndBounceAreIndependentlyGated() {
        let bannerOnly = decide(from: .working, to: .attention, notifyOnAttention: true, bounceDock: false)
        XCTAssertTrue(bannerOnly.shouldBanner)
        XCTAssertFalse(bannerOnly.shouldBounceDock)

        let bounceOnly = decide(from: .working, to: .attention, notifyOnAttention: false, bounceDock: true)
        XCTAssertFalse(bounceOnly.shouldBanner)
        XCTAssertTrue(bounceOnly.shouldBounceDock)
    }

    // MARK: finished transition -- tied to a defined completion transition

    func test_toIdle_fromWorking_isFinished() {
        let result = decide(from: .working, to: .idle)
        XCTAssertTrue(result.shouldBanner)
        XCTAssertEqual(result.bannerBody, "Agent finished")
        XCTAssertFalse(result.playSound)
        XCTAssertFalse(result.shouldBounceDock)
    }

    func test_toIdle_fromAttention_isNotFinished() {
        // Losing the attention flag is not itself a completion -- only a
        // working -> idle transition is.
        XCTAssertEqual(decide(from: .attention, to: .idle), .silent)
    }

    func test_toIdle_fromNone_isNotFinished() {
        XCTAssertEqual(decide(from: AgentStatus.none, to: .idle), .silent)
    }

    func test_toIdle_fromWorking_respectsNotifyOnFinishedToggle() {
        XCTAssertEqual(decide(from: .working, to: .idle, notifyOnFinished: false), .silent)
    }

    func test_toIdle_fromWorking_selectedAndFrontmost_isSilent() {
        XCTAssertEqual(decide(from: .working, to: .idle, isSelected: true, appActive: true), .silent)
    }

    // MARK: other transitions are silent

    func test_toWorking_fromIdle_isSilent() {
        XCTAssertEqual(decide(from: .idle, to: .working), .silent)
    }

    func test_toWorking_fromAttention_isSilent() {
        XCTAssertEqual(decide(from: .attention, to: .working), .silent)
    }

    func test_toNoneOrUnavailable_fromAnything_isSilent() {
        for to: AgentStatus in [.none, .unavailable] {
            for from: AgentStatus in [.working, .attention, .idle] {
                XCTAssertEqual(decide(from: from, to: to), .silent, "\(from) -> \(to)")
            }
        }
    }

    // MARK: known limitation of attention-first projection

    func test_mixedSession_workingAgentFinishing_isUnreachableAsAFinishedNotification() {
        // `AgentStatus.busiest` ranks `.attention` above `.working` (see its
        // doc comment) so a session with one working and one waiting agent
        // never shows `.working` at the session level -- it shows
        // `.attention` for as long as the waiting agent is waiting. If the
        // *other* agent finishes in the meantime, the session-level status
        // stays `.attention -> .attention`: no transition, so no "Agent
        // finished" notification for that agent. This is the known cost of
        // choosing an attention-first projection over representing
        // busy-ness and attention-need as two independent dimensions (the
        // ticket's other offered option) -- accepted because the
        // alternative this fixes (a waiting agent hidden behind a working
        // one) is strictly worse.
        XCTAssertEqual(decide(from: .attention, to: .attention), .silent)
    }
}
