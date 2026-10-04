//
//  ExtensionNotifierShellTests.swift
//  VaktaIntegrationTests
//
//  `notify` from a real Extension process reaching the attention
//  notifier (an in-memory delivery), and the per-Extension switch.

import UserNotifications
import XCTest
import VaktaExtensionKit
@testable import Vakta

@MainActor
private final class RecordingDelivery: NotificationDelivering {
    private(set) var delivered: [(UUID, String, String)] = []
    nonisolated func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {}
    nonisolated func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) { completion(true, nil) }
    nonisolated func deliver(sessionID: UUID, title: String, body: String, sound: Bool, completion: @escaping (Error?) -> Void) {
        Task { @MainActor in self.delivered.append((sessionID, title, body)); completion(nil) }
    }
}

@MainActor
final class ExtensionNotifierShellTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistryStore!
    private var host: ExtensionHost!
    private var delivery = RecordingDelivery()
    private var extensionNotifier: ExtensionNotifier?
    private let sessionID = UUID()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionNotifierShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("support"), withIntermediateDirectories: true)
        registry = ExtensionRegistryStore(root: base.appendingPathComponent("support"), path: { "/usr/bin:/bin" })
        let paths = try FixtureExtension.make(in: base.appendingPathComponent("fixture"))
        XCTAssertNil(registry.link(directory: paths.directory))
        let error = await registry.trust(paths.directory.standardizedFileURL.path)
        XCTAssertNil(error)
        host = ExtensionHost(
            registry: registry, supportRoot: base.appendingPathComponent("support"), hostVersion: "test",
            policy: .init(initializeTimeout: 2, shutdownGrace: 1, crashLimit: 2, crashWindow: 60, backoffBase: 0.05, backoffCap: 0.05),
            environment: { ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()] }
        )
        let notifier = AttentionNotifier(delivery: delivery, bannersAvailable: true, bounceDockAction: {})
        let sessionID = self.sessionID
        extensionNotifier = ExtensionNotifier(
            host: host, registry: registry, notifier: notifier,
            notificationsAllowed: { true }, selectedSessionID: { nil }, appActive: { true },
            sessionID: { key in key.sessionName == "vakta" ? sessionID : nil }
        )
        try await waitFor("running") { self.host.phases["fixture"] == .running }
    }

    override func tearDown() async throws {
        host?.stopAll()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try? FileManager.default.removeItem(at: base)
    }

    private struct WaitTimedOut: Error { let what: String }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw WaitTimedOut(what: what) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func pushNotify(_ title: String) throws {
        host.notify("fixture", method: "fixture/push", params: .object([
            "method": .string(ProtocolMethod.notify),
            "params": try ExtensionProtocolCodec.encode(NotifyParams(
                title: title, body: "lint", sessionKey: SessionKey(backend: "herdr", sessionName: "vakta"))),
        ]))
    }

    func test_notify_reachesTheNotifier_forItsSession() async throws {
        try pushNotify("Checks failing on #42")
        try await waitFor("delivered") { !self.delivery.delivered.isEmpty }
        XCTAssertEqual(delivery.delivered.first?.0, sessionID)
        XCTAssertEqual(delivery.delivered.first?.1, "Checks failing on #42")
        XCTAssertEqual(delivery.delivered.first?.2, "lint")
    }

    func test_notify_isDropped_whenTheExtensionsNotificationsAreOff() async throws {
        registry.setNotifications(false, for: base.appendingPathComponent("fixture").standardizedFileURL.path)
        try await waitFor("still running") { self.host.phases["fixture"] == .running }
        try pushNotify("Should not show")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(delivery.delivered.isEmpty)
    }
}
