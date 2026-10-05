//
//  StatusItemStoreShellTests.swift
//  VaktaIntegrationTests
//
//  Status Items from a real Extension process: set, clear, removal when
//  the Extension stops, and a Popover row running its button's Callback.

import XCTest
import VaktaExtensionKit
@testable import Vakta

@MainActor
final class StatusItemStoreShellTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistryStore!
    private var host: ExtensionHost!
    private var store: StatusItemStore!
    private var panes: [[String]] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusItemStoreShellTests-\(UUID().uuidString)", isDirectory: true)
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
        store = StatusItemStore(host: host, registry: registry, callbackTimeout: 2)
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

    private func push(_ method: String, _ params: JSONValue?) {
        var fields: [String: JSONValue] = ["method": .string(method)]
        if let params { fields["params"] = params }
        host.notify("fixture", method: "fixture/push", params: .object(fields))
    }

    private let popover = ViewDocument.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [
        ListSection(title: "Ready", items: [
            ListItem(id: "one", title: "One", subtitle: nil, symbol: nil, accessories: [], detail: nil, buttons: [
                ViewButton(title: "Start", symbol: "play.fill", callback: "pane", payload: nil, style: .primary, confirm: nil, shortcut: nil),
            ]),
        ]),
    ]))

    func test_statusSet_showsTheItem_andClearRemovesIt() async throws {
        push(ProtocolMethod.statusSet, try ExtensionProtocolCodec.encode(StatusSetParams(text: "3 ready", symbol: "checklist", popover: popover)))
        try await waitFor("item") { !self.store.items.isEmpty }
        XCTAssertEqual(store.items.first?.segments.first?.text, "3 ready")
        XCTAssertEqual(store.items.first?.segments.first?.popover, popover)
        XCTAssertEqual(store.items.first?.placement, .trailing)

        push(ProtocolMethod.statusClear, nil)
        try await waitFor("cleared") { self.store.items.isEmpty }
    }

    func test_extensionStopping_removesItsItem() async throws {
        push(ProtocolMethod.statusSet, try ExtensionProtocolCodec.encode(StatusSetParams(text: "3 ready", symbol: nil, popover: nil)))
        try await waitFor("item") { !self.store.items.isEmpty }

        registry.setEnabled(false, for: base.appendingPathComponent("fixture").standardizedFileURL.path)

        try await waitFor("removed") { self.store.items.isEmpty }
    }

    func test_activatingAPopoverRow_runsItsFirstButton() async throws {
        push(ProtocolMethod.statusSet, try ExtensionProtocolCodec.encode(StatusSetParams(text: "1 ready", symbol: nil, popover: popover)))
        try await waitFor("item") { !self.store.items.isEmpty }

        store.activate(StatusSegmentKey(extensionID: "fixture", index: 0), itemID: "one")

        try await waitFor("pane opened") { !self.panes.isEmpty }
        XCTAssertEqual(panes, [["echo", "hi; rm -rf /"]])
    }
}
