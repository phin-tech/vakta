//
//  ExtensionHostShellTests.swift
//  VaktaIntegrationTests
//
//  The Extension host against real child processes (FixtureExtension):
//  handshake, contexts delivery, logs, crash restart and the crash-loop
//  limit, version mismatch, initialize timeout, shutdown without orphans,
//  untrusted Extensions never starting, and request/response.

import XCTest
import VaktaExtensionKit
@testable import Vakta

@MainActor
final class ExtensionHostShellTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistryStore!
    private var host: ExtensionHost?

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionHostShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("support"), withIntermediateDirectories: true)
        registry = ExtensionRegistryStore(root: base.appendingPathComponent("support"), path: { "/usr/bin:/bin" })
    }

    override func tearDown() async throws {
        host?.stopAll()
        if let host { try? await waitFor("all stopped", timeout: 5) { host.phases.values.allSatisfy { $0 == .stopped } } }
        host = nil
        try? FileManager.default.removeItem(at: base)
    }

    private let fastPolicy = ExtensionSupervisor.Policy(
        initializeTimeout: 1, shutdownGrace: 1, crashLimit: 2, crashWindow: 60, backoffBase: 0.05, backoffCap: 0.05
    )

    /// Links and trusts the fixture, then starts a host for it.
    private func startHost(mode: String = "normal", trust: Bool = true, policy: ExtensionSupervisor.Policy? = nil) async throws -> ExtensionHost {
        let paths = try FixtureExtension.make(in: base.appendingPathComponent("fixture"))
        XCTAssertNil(registry.link(directory: paths.directory))
        if trust {
            let error = await registry.trust(paths.directory.standardizedFileURL.path)
            XCTAssertNil(error)
        }
        let host = ExtensionHost(
            registry: registry, supportRoot: base.appendingPathComponent("support"), hostVersion: "test",
            policy: policy ?? fastPolicy,
            environment: { ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "FIXTURE_MODE": mode] }
        )
        self.host = host
        return host
    }

    private func context(_ name: String, focused: Bool = false) -> ExtensionContext {
        ExtensionContext(
            sessionKey: SessionKey(backend: "herdr", sessionName: name), cwd: "/tmp", gitRoot: nil, branch: nil,
            workspace: nil, focused: focused
        )
    }

    private func log(_ host: ExtensionHost) -> String {
        (try? String(contentsOf: host.logURL(for: "fixture"))) ?? ""
    }

    private struct WaitTimedOut: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    /// Bounded polling; a timeout is a failure (never a skip).
    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw WaitTimedOut(what: what) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func phase(_ host: ExtensionHost) -> ExtensionSupervisor.Phase? { host.phases["fixture"] }

    // MARK: - Lifecycle

    func test_trustedExtension_startsAndCompletesTheHandshake() async throws {
        let host = try await startHost()
        try await waitFor("running") { phase(host) == .running }
        try await waitFor("stderr in log") { log(host).contains("fixture started") }
    }

    func test_untrustedExtension_neverStarts() async throws {
        let host = try await startHost(trust: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(phase(host))
    }

    func test_contexts_areSentAfterTheHandshake_andOnChange() async throws {
        let host = try await startHost()
        host.updateContexts([context("vakta", focused: true)])
        try await waitFor("first contexts") { log(host).contains("contexts:vakta") }

        host.updateContexts([context("vakta", focused: true), context("scratch")])
        try await waitFor("changed contexts") { log(host).contains("contexts:vakta,scratch") }
    }

    func test_crashOnce_restarts_andResendsContexts() async throws {
        let host = try await startHost(mode: "crash-once")
        host.updateContexts([context("vakta")])
        try await waitFor("restarted and running with contexts twice") {
            phase(host) == .running && log(host).components(separatedBy: "contexts:vakta").count - 1 >= 2
        }
    }

    func test_repeatedCrashes_markTheExtensionFailed() async throws {
        let host = try await startHost()
        host.updateContexts([context("crash")])
        try await waitFor("failed") { phase(host) == .failed(.crashLoop(lastExitCode: 5)) }
    }

    func test_versionMismatch_isFailed() async throws {
        let host = try await startHost(mode: "mismatch")
        try await waitFor("failed") { phase(host) == .failed(.apiVersionMismatch(2)) }
    }

    func test_initializeTimeout_endsFailedAfterTheCrashLimit() async throws {
        let host = try await startHost(mode: "hang", policy: ExtensionSupervisor.Policy(
            initializeTimeout: 0.2, shutdownGrace: 1, crashLimit: 2, crashWindow: 60, backoffBase: 0.05, backoffCap: 0.05
        ))
        try await waitFor("failed") { phase(host) == .failed(.crashLoop(lastExitCode: nil)) }
    }

    func test_restart_fromFailed_runsAgain() async throws {
        let host = try await startHost()
        host.updateContexts([context("crash")])
        try await waitFor("failed") { if case .failed = phase(host) { return true }; return false }

        host.updateContexts([context("vakta")])
        host.restart("fixture")
        try await waitFor("running") { phase(host) == .running }
    }

    func test_stopAll_shutsTheProcessDown_withoutAnOrphan() async throws {
        let host = try await startHost()
        try await waitFor("running") { phase(host) == .running }
        try await waitFor("pid logged") { log(host).contains("pid=") }
        let pidText = log(host).components(separatedBy: "pid=")[1].prefix { $0.isNumber }
        let pid = try XCTUnwrap(pid_t(pidText))

        host.stopAll()

        try await waitFor("stopped") { phase(host) == .stopped }
        try await waitFor("process gone") { kill(pid, 0) == -1 }
    }

    func test_disablingTheExtension_stopsIt() async throws {
        let host = try await startHost()
        try await waitFor("running") { phase(host) == .running }

        registry.setEnabled(false, for: base.appendingPathComponent("fixture").standardizedFileURL.path)

        try await waitFor("stopped") { phase(host) == .stopped || phase(host) == nil }
    }

    // MARK: - Environment

    func test_onlyDeclaredLoginShellVariables_reachTheExtension_andPATHStaysVaktas() async throws {
        let paths = try FixtureExtension.make(in: base.appendingPathComponent("fixture"), environment: ["FIXTURE_*"])
        XCTAssertNil(registry.link(directory: paths.directory))
        let error = await registry.trust(paths.directory.standardizedFileURL.path)
        XCTAssertNil(error)
        let host = ExtensionHost(
            registry: registry, supportRoot: base.appendingPathComponent("support"), hostVersion: "test", policy: fastPolicy,
            environment: { ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()] },
            loginEnvironment: { ["FIXTURE_SECRET": "s3cret", "OTHER": "withheld", "PATH": "/login/bin"] }
        )
        self.host = host
        try await waitFor("running") { phase(host) == .running }

        let data = try Data(contentsOf: paths.directory.appendingPathComponent("env-check.json"))
        let seen = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(seen?["FIXTURE_SECRET"] as? String, "s3cret")
        XCTAssertTrue(seen?["OTHER"] is NSNull, "undeclared variables are withheld")
        XCTAssertEqual(seen?["PATH"] as? String, "/usr/bin:/bin")
    }

    // MARK: - Pane Contexts

    private func contextWithPanes(_ name: String) -> ExtensionContext {
        ExtensionContext(
            sessionKey: SessionKey(backend: "herdr", sessionName: name), cwd: "/tmp", gitRoot: nil, branch: nil, workspace: nil,
            focused: true, panes: [PaneContext(paneID: "p1", workspace: nil, cwd: "/tmp", gitRoot: nil, branch: nil, focused: true)]
        )
    }

    func test_panes_reachOnlyExtensionsThatAskForThem() async throws {
        let host = try await startHost()
        try await waitFor("running") { phase(host) == .running }
        XCTAssertFalse(host.wantsPanes)
        host.updateContexts([contextWithPanes("vakta")])
        // The handshake's empty snapshot logs a bare "panes:"; wait for ours.
        try await waitFor("contexts logged") { log(host).contains("panes:none") || log(host).contains("panes:1") }
        XCTAssertFalse(log(host).contains("panes:1"), "a sessions-only Extension never sees panes")
    }

    func test_optedInExtension_receivesPanes() async throws {
        let paths = try FixtureExtension.make(in: base.appendingPathComponent("fixture"), contexts: "panes")
        XCTAssertNil(registry.link(directory: paths.directory))
        let error = await registry.trust(paths.directory.standardizedFileURL.path)
        XCTAssertNil(error)
        let host = ExtensionHost(
            registry: registry, supportRoot: base.appendingPathComponent("support"), hostVersion: "test", policy: fastPolicy,
            environment: { ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()] }
        )
        self.host = host
        try await waitFor("running") { phase(host) == .running }
        XCTAssertTrue(host.wantsPanes)
        host.updateContexts([contextWithPanes("vakta")])
        try await waitFor("panes logged") { log(host).contains("panes:1") }
    }

    // MARK: - Messages

    func test_request_returnsTheResult() async throws {
        let host = try await startHost()
        try await waitFor("running") { phase(host) == .running }

        let result = try await host.request("fixture", method: ProtocolMethod.viewRender, params: .object(["view": .string("items")]))

        guard case .list(let list) = try ExtensionProtocolCodec.decode(ViewDocument.self, from: result) else {
            return XCTFail("not a list")
        }
        XCTAssertEqual(list.sections.first?.items.first?.title, "First item")
    }

    func test_request_errorResponse_isRejected_andHangTimesOut() async throws {
        let host = try await startHost()
        try await waitFor("running") { phase(host) == .running }

        do {
            _ = try await host.request("fixture", method: ProtocolMethod.callback, params: .object([
                "view": .string("items"), "callback": .string("fail"),
            ]))
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? ExtensionRequestError, .rejected(JSONRPCError(code: -32000, message: "fixture failure")))
        }

        do {
            _ = try await host.request("fixture", method: ProtocolMethod.callback, params: .object([
                "view": .string("items"), "callback": .string("hang"),
            ]), timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? ExtensionRequestError, .timedOut)
        }
    }

    func test_request_toAStoppedExtension_isNotRunning() async throws {
        let host = try await startHost(trust: false)
        do {
            _ = try await host.request("fixture", method: ProtocolMethod.viewRender, params: nil)
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? ExtensionRequestError, .notRunning)
        }
    }

    func test_notificationsFromTheExtension_reachOnMessage_andLogsAreWritten() async throws {
        let host = try await startHost()
        var received: [JSONRPCMessage] = []
        let subscription = host.messages.sink { id, message in
            XCTAssertEqual(id, "fixture")
            received.append(message)
        }
        defer { subscription.cancel() }
        try await waitFor("running") { phase(host) == .running }

        host.notify("fixture", method: "fixture/push", params: .object([
            "method": .string(ProtocolMethod.statusSet), "params": .object(["text": .string("3 ready")]),
        ]))

        try await waitFor("status/set delivered") {
            received.contains(.notification(method: ProtocolMethod.statusSet, params: .object(["text": .string("3 ready")])))
        }
        host.updateContexts([context("vakta")])
        try await waitFor("log notification written") { log(host).contains("contexts:vakta") }
    }
}
