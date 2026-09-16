//
//  AttentionNotifierTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `AttentionNotifier` against an in-memory `NotificationDelivering`
//  fake and a bounce-counting closure -- asserts the resulting delivered
//  state end to end (decision -> delivery), including authorization denial
//  and delivery failure becoming observable, without touching a real
//  `UNUserNotificationCenter` (unavailable/unauthorized in a headless test).
//  `bannersAvailable: true` is passed explicitly so these exercise the same
//  decision-to-delivery wiring the packaged `.app` uses -- under plain
//  `swift test` there's no bundle identifier, so production's own check
//  would otherwise short-circuit every banner path before it ever reached
//  `delivery`.

import UserNotifications
import XCTest
@testable import Vakta

@MainActor
private final class FakeNotificationDelivery: NotificationDelivering {
    struct DeliveredNotification: Equatable {
        var sessionID: UUID
        var title: String
        var body: String
        var sound: Bool
    }

    private(set) var delivered: [DeliveredNotification] = []
    private(set) var delegateWasSet = false
    var authorizationResult: (granted: Bool, error: Error?) = (true, nil)
    var deliveryError: Error?

    nonisolated func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        Task { @MainActor in
            self.delegateWasSet = true
        }
    }

    nonisolated func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        Task { @MainActor in
            completion(self.authorizationResult.granted, self.authorizationResult.error)
        }
    }

    nonisolated func deliver(sessionID: UUID, title: String, body: String, sound: Bool, completion: @escaping (Error?) -> Void) {
        Task { @MainActor in
            self.delivered.append(DeliveredNotification(sessionID: sessionID, title: title, body: body, sound: sound))
            completion(self.deliveryError)
        }
    }
}

private struct FixtureError: Error, LocalizedError {
    var errorDescription: String? { "fixture failure" }
}

@MainActor
final class AttentionNotifierTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionNotifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Async delivery/authorization completions land via nested `Task {
    /// @MainActor in ... }` hops (the fake's own completion, then
    /// `AttentionNotifier`'s reaction to it); a few yields let all of them
    /// actually run before asserting.
    private func yield() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    // MARK: needs-attention delivery

    func test_handleTransition_toAttention_deliversBannerAndBounces() async {
        let delivery = FakeNotificationDelivery()
        var bounced = 0
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: { bounced += 1 })
        let sessionID = UUID()

        notifier.handleTransition(sessionID: sessionID, title: "My Session", from: .working, to: .attention, isSelected: false, appActive: false)
        await yield()

        XCTAssertEqual(
            delivery.delivered,
            [FakeNotificationDelivery.DeliveredNotification(sessionID: sessionID, title: "My Session", body: "Needs your attention", sound: true)]
        )
        XCTAssertEqual(bounced, 1)
    }

    func test_handleTransition_toDoneFromWorking_deliversFinishedBanner_noSound_noBounce() async {
        // `.done` (herdr's real completion signal), not `.idle` -- see
        // `AttentionTransitionPolicy`'s doc comment on the finished
        // transition.
        let delivery = FakeNotificationDelivery()
        var bounced = 0
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: { bounced += 1 })
        let sessionID = UUID()

        notifier.handleTransition(sessionID: sessionID, title: "My Session", from: .working, to: .done, isSelected: false, appActive: false)
        await yield()

        XCTAssertEqual(
            delivery.delivered,
            [FakeNotificationDelivery.DeliveredNotification(sessionID: sessionID, title: "My Session", body: "Agent finished", sound: false)]
        )
        XCTAssertEqual(bounced, 0)
    }

    func test_handleTransition_alreadyFocused_deliversNothing() async {
        let delivery = FakeNotificationDelivery()
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})

        notifier.handleTransition(sessionID: UUID(), title: "S", from: .working, to: .attention, isSelected: true, appActive: true)
        await yield()

        XCTAssertEqual(delivery.delivered, [])
    }

    func test_handleTransition_repeatedIdenticalObservations_doNotRedeliver() async {
        let delivery = FakeNotificationDelivery()
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})
        let id = UUID()

        notifier.handleTransition(sessionID: id, title: "S", from: .working, to: .attention, isSelected: false, appActive: false)
        notifier.handleTransition(sessionID: id, title: "S", from: .attention, to: .attention, isSelected: false, appActive: false)
        notifier.handleTransition(sessionID: id, title: "S", from: .attention, to: .attention, isSelected: false, appActive: false)
        await yield()

        XCTAssertEqual(delivery.delivered.count, 1, "no transition on repeats of the same observed status -- no spam")
    }

    func test_handleTransition_notifyOnAttentionOff_suppressesBannerOnly() async {
        let delivery = FakeNotificationDelivery()
        var bounced = 0
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: { bounced += 1 })
        let settings = NotificationSettingsStore(root: tempDirectory)
        settings.notifyOnAttention = false
        notifier.settings = settings

        notifier.handleTransition(sessionID: UUID(), title: "S", from: .working, to: .attention, isSelected: false, appActive: false)
        await yield()

        XCTAssertEqual(delivery.delivered, [])
        XCTAssertEqual(bounced, 1, "bounceDock is independent of notifyOnAttention")
    }

    func test_handleTransition_bounceDockOff_suppressesBounceOnly() async {
        let delivery = FakeNotificationDelivery()
        var bounced = 0
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: { bounced += 1 })
        let settings = NotificationSettingsStore(root: tempDirectory)
        settings.bounceDock = false
        notifier.settings = settings

        notifier.handleTransition(sessionID: UUID(), title: "S", from: .working, to: .attention, isSelected: false, appActive: false)
        await yield()

        XCTAssertEqual(delivery.delivered.count, 1)
        XCTAssertEqual(bounced, 0)
    }

    // MARK: authorization / delivery failure observability

    func test_requestAuthorization_denied_setsLastProblem() async {
        let delivery = FakeNotificationDelivery()
        delivery.authorizationResult = (false, nil)
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})

        notifier.requestAuthorization()
        await yield()

        XCTAssertEqual(notifier.lastProblem, .authorizationDenied)
        XCTAssertTrue(delivery.delegateWasSet)
    }

    func test_requestAuthorization_error_setsLastProblemWithDescription() async {
        let delivery = FakeNotificationDelivery()
        delivery.authorizationResult = (false, FixtureError())
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})

        notifier.requestAuthorization()
        await yield()

        XCTAssertEqual(notifier.lastProblem, .authorizationError("fixture failure"))
    }

    func test_requestAuthorization_granted_leavesLastProblemNil() async {
        let delivery = FakeNotificationDelivery()
        delivery.authorizationResult = (true, nil)
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})

        notifier.requestAuthorization()
        await yield()

        XCTAssertNil(notifier.lastProblem)
    }

    func test_deliveryFailure_setsLastProblem() async {
        let delivery = FakeNotificationDelivery()
        delivery.deliveryError = FixtureError()
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})

        notifier.handleTransition(sessionID: UUID(), title: "S", from: .working, to: .attention, isSelected: false, appActive: false)
        await yield()

        XCTAssertEqual(notifier.lastProblem, .deliveryError("fixture failure"))
    }

    func test_deliverySuccess_afterAnEarlierFailure_clearsLastProblem() async {
        let delivery = FakeNotificationDelivery()
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})
        let id = UUID()

        delivery.deliveryError = FixtureError()
        notifier.handleTransition(sessionID: id, title: "S", from: .working, to: .attention, isSelected: false, appActive: false)
        await yield()
        XCTAssertNotNil(notifier.lastProblem)

        delivery.deliveryError = nil
        notifier.handleTransition(sessionID: id, title: "S", from: .attention, to: .idle, isSelected: false, appActive: false)
        notifier.handleTransition(sessionID: id, title: "S", from: .idle, to: .working, isSelected: false, appActive: false)
        notifier.handleTransition(sessionID: id, title: "S", from: .working, to: .attention, isSelected: false, appActive: false)
        await yield()

        XCTAssertNil(notifier.lastProblem, "a later successful delivery must clear a stale earlier failure")
    }

    func test_bannersUnavailable_neverCallsDeliveryEvenWhenATransitionWouldNotify() async {
        let delivery = FakeNotificationDelivery()
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: false, bounceDockAction: {})

        notifier.handleTransition(sessionID: UUID(), title: "S", from: .working, to: .attention, isSelected: false, appActive: false)
        await yield()

        XCTAssertEqual(delivery.delivered, [], "no bundle identifier -- production's swift-run/swift-test behavior")
    }
}
