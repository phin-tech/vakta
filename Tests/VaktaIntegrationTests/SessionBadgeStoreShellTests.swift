//
//  SessionBadgeStoreShellTests.swift
//  VaktaIntegrationTests
//
//  Session Badges from a real Extension process: set and clear per Session
//  Key, removal when the Extension stops, and a Popover row running its
//  button.

import XCTest
import VaktaExtensionKit
@testable import Vakta

@MainActor
final class SessionBadgeStoreShellTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistryStore!
    private var host: ExtensionHost!
    private var store: SessionBadgeStore!
    private var panes: [[String]] = []
    private let vakta = SessionKey(backend: "herdr", sessionName: "vakta")
    private let other = SessionKey(backend: "tmux", sessionName: "other")

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionBadgeStoreShellTests-\(UUID().uuidString)", isDirectory: true)
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
        store = SessionBadgeStore(host: host, registry: registry, callbackTimeout: 2)
        store.effectSink = PanelEffectSink(
            openURL: { _ in }, notify: { _, _ in },
            openPane: { [weak self] _, command, _ in self?.panes.append(command); return nil },
            openSession: { _, _, _ in nil }
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

    private func push(_ method: String, _ params: Encodable) throws {
        host.notify("fixture", method: "fixture/push", params: .object([
            "method": .string(method), "params": try ExtensionProtocolCodec.encode(AnyEncodable(params)),
        ]))
    }

    private struct AnyEncodable: Encodable {
        let value: Encodable
        init(_ value: Encodable) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    func test_badgeSet_showsOnThatSessionOnly_andClearRemovesIt() async throws {
        try push(ProtocolMethod.badgeSet, BadgeSetParams(sessionKey: vakta, text: "fcae", symbol: "circle.fill", popover: nil))
        try await waitFor("badge") { self.store.display(for: self.vakta) != nil }
        XCTAssertEqual(store.display(for: vakta)?.shown.text, "fcae")
        XCTAssertNil(store.display(for: other))

        try push(ProtocolMethod.badgeClear, BadgeClearParams(sessionKey: vakta))
        try await waitFor("cleared") { self.store.display(for: self.vakta) == nil }
    }

    func test_extensionStopping_removesItsBadges() async throws {
        try push(ProtocolMethod.badgeSet, BadgeSetParams(sessionKey: vakta, text: "fcae", symbol: nil, popover: nil))
        try push(ProtocolMethod.badgeSet, BadgeSetParams(sessionKey: other, text: "7cq8", symbol: nil, popover: nil))
        try await waitFor("badges") { self.store.display(for: self.other) != nil }

        registry.setEnabled(false, for: base.appendingPathComponent("fixture").standardizedFileURL.path)

        try await waitFor("removed") { self.store.display(for: self.vakta) == nil && self.store.display(for: self.other) == nil }
    }

    func test_activatingAPopoverRow_runsItsFirstButton() async throws {
        let popover = ViewDocument.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [
            ListSection(title: nil, items: [ListItem(id: "fcae", title: "fcae", subtitle: nil, symbol: nil, accessories: [], detail: nil, buttons: [
                ViewButton(title: "Open", symbol: nil, callback: "pane", payload: nil, style: .default, confirm: nil, shortcut: nil),
            ])]),
        ]))
        try push(ProtocolMethod.badgeSet, BadgeSetParams(sessionKey: vakta, text: "fcae", symbol: nil, popover: popover))
        try await waitFor("badge") { self.store.display(for: self.vakta) != nil }

        store.activate(extensionID: "fixture", sessionKey: vakta, itemID: "fcae")

        try await waitFor("pane opened") { !self.panes.isEmpty }
    }
}
