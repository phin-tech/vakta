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

/// Buttons against the real fixture process: Callbacks, every Effect kind,
/// one press in flight, failures and timeouts, and stale results.
@MainActor
final class PanelViewCallbackShellTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistryStore!
    private var host: ExtensionHost!
    private var store: PanelViewStore!
    private let items = PanelViewRef(extensionID: "fixture", viewID: "items")

    /// Records what reached the sink (a stateful in-memory boundary).
    private final class Outcomes {
        var urls: [URL] = []
        var notices: [String] = []
        var panes: [[String]] = []
    }
    private var outcomes = Outcomes()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelViewCallbackShellTests-\(UUID().uuidString)", isDirectory: true)
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
        store = PanelViewStore(host: host, callbackTimeout: 0.5)
        let outcomes = self.outcomes
        store.effectSink = PanelEffectSink(
            openURL: { outcomes.urls.append($0) },
            notify: { title, body in outcomes.notices.append([title, body ?? ""].joined(separator: ": ")) },
            openPane: { _, command, _ in outcomes.panes.append(command); return nil },
            openSession: { _, _, _ in "no sessions in tests" }
        )
        host.updateContexts([context("alpha")])
        store.activate(items)
        try await waitFor("rendered") { subtitle()?.hasPrefix("render") == true }
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

    private func context(_ name: String) -> ExtensionContext {
        ExtensionContext(sessionKey: SessionKey(backend: "herdr", sessionName: name), cwd: "/tmp", gitRoot: nil, branch: nil, workspace: nil, focused: true)
    }

    private func subtitle() -> String? {
        guard case .document(.list(let list)) = store.model.content else { return nil }
        return list.sections.first?.items.first?.subtitle
    }

    private func button(_ callback: String, payload: JSONValue? = nil) -> ViewButton {
        ViewButton(title: callback, symbol: nil, callback: callback, payload: payload, style: .default, confirm: nil, shortcut: nil)
    }

    func test_refreshEffect_reRenders() async throws {
        store.press(button("refresh"))
        try await waitFor("second render") { subtitle()?.hasPrefix("render 2") == true }
        XCTAssertEqual(store.callbackState(button("refresh")), .idle)
    }

    func test_payloadAndFormValues_reachTheExtension() async throws {
        store.press(button("echo", payload: .object(["id": .string("fcae")])), form: ["message": .string("done")])
        try await waitFor("toast") { store.toast != nil }
        XCTAssertEqual(store.toast, #"{"form": {"message": "done"}, "payload": {"id": "fcae"}}"#)
    }

    func test_errorResponse_marksTheButtonFailed_untilTheNextRender() async throws {
        store.press(button("fail"))
        try await waitFor("failed") { store.callbackState(button("fail")) == .failed("fixture failure") }

        store.refresh()
        try await waitFor("cleared by render") { store.callbackState(button("fail")) == .idle }
    }

    func test_secondPressWhilePending_isIgnored_andATimeoutFails() async throws {
        store.press(button("hang"))
        XCTAssertEqual(store.callbackState(button("hang")), .pending)
        store.press(button("hang"))

        try await waitFor("timed out") {
            if case .failed = store.callbackState(button("hang")) { return true }
            return false
        }
        XCTAssertEqual(store.callbackState(button("hang")), .failed("The extension didn't answer in time."))
    }

    func test_pushAndPopEffects_navigate() async throws {
        store.press(button("navigate"))
        try await waitFor("pushed") { store.model.visibleDocument == .detail(DetailView(title: "Pushed", markdown: nil, fields: [], buttons: [])) }

        store.press(button("back"))
        try await waitFor("popped") { !store.model.isShowingDetail && store.toast == "popped" }
    }

    private func visibleForm() -> FormView? {
        if case .form(let form)? = store.model.visibleDocument { return form }
        return nil
    }

    func test_form_blocksAnIncompleteSubmit_thenSendsTheValues() async throws {
        store.press(button("form"))
        try await waitFor("form pushed") { visibleForm() != nil }
        let form = try XCTUnwrap(visibleForm())

        store.submitForm(form)
        XCTAssertTrue(store.formState(for: form).attemptedSubmit)
        XCTAssertEqual(store.formState(for: form).problems, ["message": "Required"])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(store.toast, "an incomplete form sends nothing")

        store.editForm(form) { $0.setText("message", "done") }
        store.editForm(form) { $0.setToggle("notify", false) }
        store.submitForm(form)

        try await waitFor("echo toast") { store.toast != nil }
        XCTAssertEqual(store.toast, #"{"form": {"message": "done", "notify": false}, "payload": {"id": "one"}}"#)
    }

    func test_formEdits_resetWhenADifferentFormIsShown() async throws {
        store.press(button("form"))
        try await waitFor("form pushed") { visibleForm() != nil }
        let form = try XCTUnwrap(visibleForm())
        store.editForm(form) { $0.setText("message", "draft") }
        XCTAssertEqual(store.formState(for: form).text("message"), "draft")

        let other = FormView(title: "Other", fields: form.fields, submit: form.submit)
        XCTAssertEqual(store.formState(for: other).text("message"), "")
    }

    func test_openURLAndNotify_reachTheSink() async throws {
        store.press(button("open"))
        try await waitFor("sink") { !outcomes.urls.isEmpty && !outcomes.notices.isEmpty }
        XCTAssertEqual(outcomes.urls, [URL(string: "https://example.com/issue")!])
        XCTAssertEqual(outcomes.notices, ["Opened: issue"])
    }

    func test_openPane_passesArgvUntouched() async throws {
        store.press(button("pane"))
        try await waitFor("pane") { !outcomes.panes.isEmpty }
        XCTAssertEqual(outcomes.panes, [["echo", "hi; rm -rf /"]])
    }

    func test_staleResult_dropsTheRefresh_butKeepsTheToast() async throws {
        store.press(button("slow")) // answers after 0.3s, inside the 0.5s timeout
        try await Task.sleep(nanoseconds: 50_000_000)
        host.updateContexts([context("beta")])
        try await waitFor("beta render") { subtitle()?.hasSuffix("for beta") == true }
        let renderedForBeta = subtitle()

        try await waitFor("toast") { store.toast == "slow done" }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(subtitle(), renderedForBeta, "the stale refresh must not re-render")
    }
}
