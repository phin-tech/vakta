//
//  ExtensionServerTests.swift
//  VaktaExtensionServerTests
//
//  The Swift Extension runtime, driven through the in-memory harness:
//  handshake, contexts, routing, error responses, publishing only changes,
//  and shutdown.

import XCTest
import VaktaExtensionKit
@testable import VaktaExtensionServer

final class ExtensionServerTests: XCTestCase {
    private let vakta = SessionKey(backend: "herdr", sessionName: "vakta")
    private let other = SessionKey(backend: "tmux", sessionName: "other")

    private func context(_ key: SessionKey, focused: Bool) -> ExtensionContext {
        ExtensionContext(sessionKey: key, cwd: "/r", gitRoot: "/r", branch: "main", workspace: nil, focused: focused)
    }

    func test_initialize_answersWithNameAndAPI_thenCallsOnReady() throws {
        var ready = false
        let harness = ExtensionHarness { transport in
            let server = ExtensionServer(name: "Demo", transport: transport)
            server.onReady = { ready = true }
            return server
        }
        XCTAssertEqual(try harness.initialize(), InitializeResult(apiVersion: vaktaExtensionAPIVersion, name: "Demo"))
        XCTAssertTrue(ready)
    }

    func test_contexts_areKept_andReportedWithThePrevious() {
        var seen: [(Int, Int)] = []
        let harness = ExtensionHarness { transport in
            let server = ExtensionServer(name: "Demo", transport: transport)
            server.onContexts = { previous, current in seen.append((previous.count, current.count)) }
            return server
        }
        harness.send(contexts: [context(vakta, focused: true)])
        harness.send(contexts: [context(vakta, focused: false), context(other, focused: true)])
        XCTAssertEqual(seen.map(\.0), [0, 1])
        XCTAssertEqual(seen.map(\.1), [1, 2])
        XCTAssertEqual(harness.server.focusedContext?.sessionKey, other)
    }

    func test_renderAndCallback_routeToHandlers() throws {
        let harness = ExtensionHarness { transport in
            let server = ExtensionServer(name: "Demo", transport: transport)
            server.onRender("items") { .detail(DetailView(title: "Hello", markdown: nil, fields: [], buttons: [])) }
            server.onCallback("echo") { params in [.toast(text: "\(params.payload ?? .null)")] }
            return server
        }
        XCTAssertEqual(try harness.render("items"), .detail(DetailView(title: "Hello", markdown: nil, fields: [], buttons: [])))
        XCTAssertEqual(try harness.callback("echo", payload: .string("x")), [.toast(text: "string(\"x\")")])
    }

    func test_unknownViewOrCallback_andThrownErrors_becomeErrorResponses() {
        let harness = ExtensionHarness { transport in
            let server = ExtensionServer(name: "Demo", transport: transport)
            server.onCallback("fail") { _ in throw ExtensionError("kata said no") }
            return server
        }
        XCTAssertThrowsError(try harness.render("nope")) { XCTAssertEqual($0 as? ExtensionError, ExtensionError.invalidParams("no view nope")) }
        XCTAssertThrowsError(try harness.callback("missing")) { XCTAssertEqual(($0 as? ExtensionError)?.code, -32601) }
        XCTAssertThrowsError(try harness.callback("fail")) { XCTAssertEqual($0 as? ExtensionError, ExtensionError("kata said no")) }
        XCTAssertThrowsError(try harness.request("other/method", Optional<String>.none)) { XCTAssertEqual(($0 as? ExtensionError)?.code, -32601) }
    }

    func test_status_isSentOnlyWhenItChanges_andNilClears() {
        let harness = ExtensionHarness { ExtensionServer(name: "Demo", transport: $0) }
        let status = StatusSetParams(text: "3 ready", symbol: nil, popover: nil)
        harness.server.queue.sync {
            harness.server.setStatus(status)
            harness.server.setStatus(status)
            harness.server.setStatus(nil)
            harness.server.setStatus(nil)
        }
        XCTAssertEqual(harness.notifications(ProtocolMethod.statusSet, as: StatusSetParams.self), [status])
        XCTAssertEqual(harness.count(ProtocolMethod.statusClear), 1)
    }

    func test_badges_areDiffed() {
        let harness = ExtensionHarness { ExtensionServer(name: "Demo", transport: $0) }
        let a = BadgeSetParams(sessionKey: vakta, text: "#1", symbol: nil, popover: nil)
        let b = BadgeSetParams(sessionKey: other, text: "#2", symbol: nil, popover: nil)
        harness.server.queue.sync {
            harness.server.setBadges([vakta: a, other: b])
            harness.server.setBadges([vakta: a])
        }
        XCTAssertEqual(harness.notifications(ProtocolMethod.badgeSet, as: BadgeSetParams.self).count, 2, "a isn't resent")
        XCTAssertEqual(harness.notifications(ProtocolMethod.badgeClear, as: BadgeClearParams.self), [BadgeClearParams(sessionKey: other)])
    }

    /// `setBadges` must clear a badge by its own `sessionKey`, not by the
    /// dictionary key the caller happened to store it under -- a caller
    /// bug (mismatched key) must not orphan the badge Vakta actually knows
    /// about under the wrong Session.
    func test_badgeClear_namesTheBadgesOwnSessionKey_notTheDictionaryKeyItWasStoredUnder() {
        let harness = ExtensionHarness { ExtensionServer(name: "Demo", transport: $0) }
        let mismatched = BadgeSetParams(sessionKey: vakta, text: "#1", symbol: nil, popover: nil)
        harness.server.queue.sync {
            harness.server.setBadges([other: mismatched])
            harness.server.setBadges([:])
        }
        XCTAssertEqual(
            harness.notifications(ProtocolMethod.badgeClear, as: BadgeClearParams.self),
            [BadgeClearParams(sessionKey: vakta)]
        )
    }

    func test_commands_areSentOnlyWhenTheyChange() {
        let harness = ExtensionHarness { ExtensionServer(name: "Demo", transport: $0) }
        let commands = [ExtensionCommand(id: "a", title: "A", symbol: nil, callback: "a", payload: nil)]
        harness.server.queue.sync {
            harness.server.setCommands([])
            harness.server.setCommands([])
            harness.server.setCommands(commands)
        }
        XCTAssertEqual(harness.notifications(ProtocolMethod.commandsSet, as: CommandsSetParams.self).map(\.commands), [[], commands])
    }

    func test_otherPublishers() {
        let harness = ExtensionHarness { ExtensionServer(name: "Demo", transport: $0) }
        harness.server.queue.sync {
            harness.server.notify(title: "Done", body: "b", sessionKey: self.vakta)
            harness.server.invalidate(view: "items")
            harness.server.log(.warning, "careful")
        }
        XCTAssertEqual(harness.notifications(ProtocolMethod.notify, as: NotifyParams.self), [NotifyParams(title: "Done", body: "b", sessionKey: vakta)])
        XCTAssertEqual(harness.notifications(ProtocolMethod.viewInvalidate, as: ViewInvalidateParams.self), [ViewInvalidateParams(view: "items")])
        XCTAssertEqual(harness.notifications(ProtocolMethod.log, as: LogParams.self), [LogParams(level: .warning, message: "careful")])
    }

    func test_shutdown_answers_runsTheHook_andExits() throws {
        var hooked = false
        let harness = ExtensionHarness { transport in
            let server = ExtensionServer(name: "Demo", transport: transport)
            server.onShutdown = { hooked = true }
            return server
        }
        try harness.shutdown()
        XCTAssertTrue(hooked)
        XCTAssertTrue(harness.exited)
    }
}
