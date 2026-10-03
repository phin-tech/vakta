//
//  PanelViewStoreShellTests.swift
//  VaktaIntegrationTests
//
//  The Panel View against a real Extension process (FixtureExtension):
//  render on activation, pushed updates, invalidation, re-render on a focus
//  change, and the unavailable state when the Extension stops or was never
//  approved.

import Combine
import XCTest
import VaktaExtensionKit
@testable import Vakta

@MainActor
final class PanelViewStoreShellTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistryStore!
    private var host: ExtensionHost!
    private let items = PanelViewRef(extensionID: "fixture", viewID: "items")

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelViewStoreShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("support"), withIntermediateDirectories: true)
        registry = ExtensionRegistryStore(root: base.appendingPathComponent("support"), path: { "/usr/bin:/bin" })
    }

    override func tearDown() async throws {
        host?.stopAll()
        try? await Task.sleep(nanoseconds: 200_000_000)
        host = nil
        try? FileManager.default.removeItem(at: base)
    }

    private func start(trust: Bool = true) async throws -> PanelViewStore {
        let paths = try FixtureExtension.make(in: base.appendingPathComponent("fixture"))
        XCTAssertNil(registry.link(directory: paths.directory))
        if trust {
            let error = await registry.trust(paths.directory.standardizedFileURL.path)
            XCTAssertNil(error)
        }
        host = ExtensionHost(
            registry: registry, supportRoot: base.appendingPathComponent("support"), hostVersion: "test",
            policy: .init(initializeTimeout: 2, shutdownGrace: 1, crashLimit: 2, crashWindow: 60, backoffBase: 0.05, backoffCap: 0.05),
            environment: { ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()] }
        )
        return PanelViewStore(host: host)
    }

    private struct WaitTimedOut: Error { let what: String }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw WaitTimedOut(what: what) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func firstSubtitle(_ store: PanelViewStore) -> String? {
        guard case .document(.list(let list)) = store.model.content else { return nil }
        return list.sections.first?.items.first?.subtitle
    }

    private func context(_ name: String) -> ExtensionContext {
        ExtensionContext(sessionKey: SessionKey(backend: "herdr", sessionName: name), cwd: "/tmp", gitRoot: nil, branch: nil, workspace: nil, focused: true)
    }

    func test_activate_rendersOnceTheExtensionIsRunning() async throws {
        let store = try await start()
        store.activate(items)
        try await waitFor("rendered") { firstSubtitle(store)?.hasPrefix("render") == true }
        XCTAssertEqual(store.active, items)
    }

    func test_pushedUpdate_replacesTheDocument() async throws {
        let store = try await start()
        store.activate(items)
        try await waitFor("rendered") { firstSubtitle(store) != nil }

        let pushed = ViewDocument.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [
            ListSection(title: "Pushed", items: [ListItem(id: "p", title: "Pushed", subtitle: "pushed", symbol: nil, accessories: [], detail: nil, buttons: [])]),
        ]))
        host.notify("fixture", method: "fixture/push", params: .object([
            "method": .string(ProtocolMethod.viewUpdate),
            "params": try ExtensionProtocolCodec.encode(ViewUpdateParams(view: "items", document: pushed)),
        ]))

        try await waitFor("pushed applied") { store.model.content == .document(pushed) }
    }

    func test_updateForAnotherView_isIgnored() async throws {
        let store = try await start()
        store.activate(items)
        try await waitFor("rendered") { firstSubtitle(store) != nil }
        let before = store.model.content

        host.notify("fixture", method: "fixture/push", params: .object([
            "method": .string(ProtocolMethod.viewUpdate),
            "params": try ExtensionProtocolCodec.encode(ViewUpdateParams(view: "other", document: .list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [])))),
        ]))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.model.content, before)
    }

    func test_invalidate_reRenders() async throws {
        let store = try await start()
        store.activate(items)
        try await waitFor("first render") { firstSubtitle(store)?.hasPrefix("render 1") == true }

        host.notify("fixture", method: "fixture/push", params: .object([
            "method": .string(ProtocolMethod.viewInvalidate), "params": .object(["view": .string("items")]),
        ]))

        try await waitFor("second render") { firstSubtitle(store)?.hasPrefix("render 2") == true }
    }

    func test_focusChange_reRendersForTheNewSession() async throws {
        let store = try await start()
        host.updateContexts([context("alpha")])
        store.activate(items)
        try await waitFor("alpha render") { firstSubtitle(store)?.hasSuffix("for alpha") == true }

        host.updateContexts([context("beta")])

        try await waitFor("beta render") { firstSubtitle(store)?.hasSuffix("for beta") == true }
    }

    func test_renderError_isShown() async throws {
        let store = try await start()
        store.activate(PanelViewRef(extensionID: "fixture", viewID: "broken"))
        try await waitFor("error") { store.model.content == .error("fixture can't render") }
    }

    func test_extensionStopping_marksTheViewUnavailable() async throws {
        let store = try await start()
        store.activate(items)
        try await waitFor("rendered") { firstSubtitle(store) != nil }

        registry.setEnabled(false, for: base.appendingPathComponent("fixture").standardizedFileURL.path)

        try await waitFor("unavailable") { if case .unavailable = store.model.content { return true }; return false }
    }

    func test_untrustedExtension_isUnavailable() async throws {
        let store = try await start(trust: false)
        store.activate(items)
        try await waitFor("unavailable") { if case .unavailable = store.model.content { return true }; return false }
    }

    func test_deactivate_stopsFollowingTheView() async throws {
        let store = try await start()
        store.activate(items)
        try await waitFor("rendered") { firstSubtitle(store) != nil }

        store.activate(nil)

        XCTAssertNil(store.active)
        XCTAssertEqual(store.model.content, .loading)
    }
}
