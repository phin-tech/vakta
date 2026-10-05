//
//  ExtensionCommandStoreShellTests.swift
//  VaktaIntegrationTests
//
//  ⌘K Commands from a real Extension process: a set replaces the previous
//  one, choosing a Command runs its Callback, and Commands vanish when the
//  Extension stops.

import XCTest
import VaktaExtensionKit
@testable import Vakta

@MainActor
final class ExtensionCommandStoreShellTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistryStore!
    private var host: ExtensionHost!
    private var store: ExtensionCommandStore!
    private var panes: [[String]] = []

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionCommandStoreShellTests-\(UUID().uuidString)", isDirectory: true)
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
        store = ExtensionCommandStore(host: host, registry: registry, callbackTimeout: 2)
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

    private func pushCommands(_ commands: [ExtensionCommand]) throws {
        host.notify("fixture", method: "fixture/push", params: .object([
            "method": .string(ProtocolMethod.commandsSet),
            "params": try ExtensionProtocolCodec.encode(CommandsSetParams(commands: commands)),
        ]))
    }

    func test_commandsSet_replacesTheList_labelledWithTheExtensionName() async throws {
        try pushCommands([ExtensionCommand(id: "a", title: "First", symbol: nil, callback: "pane", payload: nil)])
        try await waitFor("first set") { self.store.entries.map(\.id) == ["a"] }
        XCTAssertEqual(store.entries.first?.extensionName, "Fixture")

        try pushCommands([ExtensionCommand(id: "b", title: "Second", symbol: nil, callback: "pane", payload: nil)])
        try await waitFor("replaced") { self.store.entries.map(\.id) == ["b"] }
    }

    func test_runningACommand_sendsItsCallback() async throws {
        try pushCommands([ExtensionCommand(id: "go", title: "Go", symbol: nil, callback: "pane", payload: nil)])
        try await waitFor("set") { !self.store.entries.isEmpty }

        store.run(extensionID: "fixture", commandID: "go")

        try await waitFor("pane opened") { !self.panes.isEmpty }
    }

    func test_extensionStopping_removesItsCommands() async throws {
        try pushCommands([ExtensionCommand(id: "go", title: "Go", symbol: nil, callback: "pane", payload: nil)])
        try await waitFor("set") { !self.store.entries.isEmpty }

        registry.setEnabled(false, for: base.appendingPathComponent("fixture").standardizedFileURL.path)

        try await waitFor("removed") { self.store.entries.isEmpty }
    }
}
