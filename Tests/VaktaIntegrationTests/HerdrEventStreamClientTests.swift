//
//  HerdrEventStreamClientTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `HerdrEventStreamClient` against a real fixture Unix
//  socket server (`FixtureHerdrSocketServer`) -- no mocks. Covers the
//  behaviors docs/herdr-events-plan.md's design commits to: subscribing on
//  connect, triggering on a relevant frame (but not an ack), reconnecting
//  with a full new subscription list when the pane-id set changes (no live
//  patching -- confirmed against the real protocol), reconnecting after a
//  dropped connection, and a clean stop that doesn't keep reconnecting.
//
//  Socket paths here are short and fixed under `/tmp` directly (not the
//  shared UUID-suffixed temp-directory helper other tests use) -- Darwin's
//  `sun_path` is 104 bytes and a bind can fail past that.

import Network
import XCTest
@testable import Vakta

final class HerdrEventStreamClientTests: XCTestCase {
    private var socketPath: String!
    private var server: FixtureHerdrSocketServer!
    private var client: HerdrEventStreamClient!

    override func setUpWithError() throws {
        socketPath = "/tmp/vakta-hesc-\(UInt32.random(in: 0...UInt32.max)).sock"
        server = try FixtureHerdrSocketServer(path: socketPath)
    }

    override func tearDownWithError() throws {
        client?.stop()
        server?.stop()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func makeClient(paneIDs: Set<String> = ["w1:p1"], reconnectDelay: @escaping (Int) -> TimeInterval = { _ in 0 }) -> HerdrEventStreamClient {
        HerdrEventStreamClient(
            socketPath: URL(fileURLWithPath: socketPath),
            initialPaneIDs: paneIDs,
            reconnectDelay: reconnectDelay
        )
    }

    func test_start_connectsAndSendsASubscribeRequest() {
        let received = expectation(description: "request line received")
        server.onLineReceived = { _, line in
            XCTAssertTrue(line.contains("events.subscribe"))
            XCTAssertTrue(line.contains("w1:p1"))
            received.fulfill()
        }

        client = makeClient()
        client.start()

        wait(for: [received], timeout: 5)
    }

    func test_subscriptionAckAlone_doesNotFireOnTrigger() {
        let acked = expectation(description: "ack sent")
        server.onLineReceived = { [server] index, _ in
            server?.send(#"{"id":"vakta_sub","result":{"type":"subscription_started"}}"#, toConnectionAt: index)
            acked.fulfill()
        }
        let triggered = expectation(description: "onTrigger should not fire")
        triggered.isInverted = true

        client = makeClient()
        client.onTrigger = { triggered.fulfill() }
        client.start()

        wait(for: [acked], timeout: 5)
        wait(for: [triggered], timeout: 1)
    }

    func test_paneAgentStatusChangedEvent_firesOnTrigger() {
        server.onLineReceived = { [server] index, _ in
            server?.send(#"{"data":{"agent":"claude","agent_status":"working","pane_id":"w1:p1"},"event":"pane.agent_status_changed"}"#, toConnectionAt: index)
        }
        let triggered = expectation(description: "onTrigger fires")

        client = makeClient()
        client.onTrigger = { triggered.fulfill() }
        client.start()

        wait(for: [triggered], timeout: 5)
    }

    func test_malformedLine_firesOnTrigger() {
        server.onLineReceived = { [server] index, _ in
            server?.send("not valid json at all", toConnectionAt: index)
        }
        let triggered = expectation(description: "onTrigger fires on malformed line")

        client = makeClient()
        client.onTrigger = { triggered.fulfill() }
        client.start()

        wait(for: [triggered], timeout: 5)
    }

    func test_updatePaneIDs_opensANewConnectionWithTheFullUpdatedList() {
        let firstConnected = expectation(description: "first connection subscribed")
        server.onLineReceived = { _, line in
            if line.contains("w1:p1") { firstConnected.fulfill() }
        }

        client = makeClient(paneIDs: ["w1:p1"])
        client.start()
        wait(for: [firstConnected], timeout: 5)

        let secondConnected = expectation(description: "second connection subscribed with updated set")
        server.onLineReceived = { _, line in
            if line.contains("w2:p1") { secondConnected.fulfill() }
        }
        client.updatePaneIDs(["w2:p1"])
        wait(for: [secondConnected], timeout: 5)

        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertFalse(server.requestLines(forConnectionAt: 1).first?.contains("w1:p1") ?? true)
    }

    func test_connectionDroppedByServer_reconnectsAutomatically() {
        let firstConnected = expectation(description: "first connection")
        server.onNewConnection = { index in
            if index == 0 { firstConnected.fulfill() }
        }

        client = makeClient()
        client.start()
        wait(for: [firstConnected], timeout: 5)

        let secondConnected = expectation(description: "reconnected after drop")
        server.onNewConnection = { index in
            if index == 1 { secondConnected.fulfill() }
        }
        server.closeConnection(at: 0)

        wait(for: [secondConnected], timeout: 5)
        XCTAssertEqual(server.connectionCount, 2)
    }

    func test_stop_doesNotReconnectAfterADrop() {
        let firstConnected = expectation(description: "first connection")
        server.onNewConnection = { index in
            if index == 0 { firstConnected.fulfill() }
        }

        client = makeClient()
        client.start()
        wait(for: [firstConnected], timeout: 5)

        client.stop()
        server.closeConnection(at: 0)

        // Give any (incorrect) reconnect attempt a moment to happen.
        let noReconnect = expectation(description: "no reconnect after stop")
        noReconnect.isInverted = true
        server.onNewConnection = { _ in noReconnect.fulfill() }
        wait(for: [noReconnect], timeout: 1)

        XCTAssertEqual(server.connectionCount, 1)
    }
}
