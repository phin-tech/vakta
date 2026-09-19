//
//  FixtureHerdrSocketServer.swift
//  VaktaIntegrationTests
//
//  A real Unix domain socket server speaking just enough of herdr's socket
//  protocol (newline-delimited JSON) to drive `HerdrEventStreamClient`
//  tests -- no mocks. Built on the same `NWListener`/`requiredLocalEndpoint`
//  pattern verified in a standalone spike against both a fixture and the
//  real herdr server (see docs/herdr-events-plan.md). Records every request
//  line per connection and lets a test push lines or drop a connection on
//  demand, driven by `XCTestExpectation` rather than sleeping.

import Network
import XCTest
@testable import Vakta

final class FixtureHerdrSocketServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FixtureHerdrSocketServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var requestLinesByConnection: [[String]] = []

    /// Called (on the fixture's own queue) whenever a new connection is
    /// accepted, with its index.
    var onNewConnection: ((Int) -> Void)?
    /// Called (on the fixture's own queue) for every decoded request line,
    /// with the owning connection's index.
    var onLineReceived: ((Int, String) -> Void)?

    init(path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let endpoint = NWEndpoint.unix(path: path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = endpoint
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let all = connections
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        lock.lock()
        connections.append(connection)
        requestLinesByConnection.append([])
        let index = connections.count - 1
        lock.unlock()
        onNewConnection?(index)
        receiveLoop(connection: connection, index: index, buffer: Data())
    }

    private func receiveLoop(connection: NWConnection, index: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }
            let (lines, remainder) = HerdrSocketDecoder.extractLines(from: buffer)
            for line in lines {
                self.lock.lock()
                self.requestLinesByConnection[index].append(line)
                self.lock.unlock()
                self.onLineReceived?(index, line)
            }
            if !isComplete, error == nil {
                self.receiveLoop(connection: connection, index: index, buffer: remainder)
            }
        }
    }

    /// Sends one line (a newline is appended) down the connection at
    /// `index` -- the order connections were accepted in.
    func send(_ line: String, toConnectionAt index: Int) {
        lock.lock()
        let connection = connections[index]
        lock.unlock()
        connection.send(content: (line + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
    }

    /// Drops the connection at `index`, simulating the server closing it.
    func closeConnection(at index: Int) {
        lock.lock()
        let connection = connections[index]
        lock.unlock()
        connection.cancel()
    }

    func requestLines(forConnectionAt index: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLinesByConnection[index]
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }
}
