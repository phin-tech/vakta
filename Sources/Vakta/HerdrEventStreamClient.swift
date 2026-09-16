//
//  HerdrEventStreamClient.swift
//  Vakta
//
//  Owns one socket connection per herdr session, subscribed to lifecycle
//  events (`pane.created`/`pane.closed`/`pane.agent_detected`, session-wide
//  per herdr's schema) plus `pane.agent_status_changed` for every pane id
//  currently known to belong to that session's agents. Never carries status
//  data to its caller -- see docs/herdr-events-plan.md's design pivot: any
//  relevant frame just calls `onTrigger`, telling `SessionStore` to re-run
//  its existing, unchanged `pollAgentStatus()` early instead of waiting for
//  the fallback timer tick.
//
//  Uses `NWConnection`/`NWEndpoint.unix(path:)` (verified compatible with
//  the macOS 13 deployment target, and against a real herdr server, in a
//  standalone spike -- see docs/herdr-events-plan.md).
//
//  Thread-confined to its own private serial `queue`, not `@MainActor`: the
//  read loop and connection-state callbacks run in the background by
//  nature (Network framework delivers them on whatever queue `start(queue:)`
//  names), so every mutable property here is touched only on `queue`.
//  Public methods are safe to call from any thread/actor (including the
//  main actor) -- they just dispatch onto `queue` internally. `onTrigger`
//  fires on `queue`, not the main actor; the caller (`SessionStore`) is
//  responsible for hopping to main itself, same as `pollAgentStatus`'s
//  existing background-completion pattern.

import Foundation
import Network

final class HerdrEventStreamClient: @unchecked Sendable {
    /// Called for any frame that means "something might have changed" --
    /// a pane lifecycle event, a status-change event, or an undecodable
    /// line (treated the same: reconnect and let the next poll settle the
    /// truth). Never fires for `subscriptionAck`/`other`. Fires on `queue`.
    var onTrigger: (() -> Void)?

    private let socketPath: URL
    private let queue: DispatchQueue
    /// `attempt -> delay`, injectable so tests don't wait on real backoff.
    private let reconnectDelay: (Int) -> TimeInterval

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var subscribedPaneIDs: Set<String>
    private var reconnectAttempt = 0
    private var isStopped = true
    /// Bumped on every `start`/`stop`/`updatePaneIDs`/reconnect so a
    /// completion handler from a superseded connection can't act after the
    /// fact.
    private var generation = 0

    init(
        socketPath: URL,
        initialPaneIDs: Set<String>,
        queue: DispatchQueue = DispatchQueue(label: "HerdrEventStreamClient"),
        reconnectDelay: @escaping (Int) -> TimeInterval = { attempt in min(pow(2.0, Double(attempt)), 30) }
    ) {
        self.socketPath = socketPath
        self.subscribedPaneIDs = initialPaneIDs
        self.queue = queue
        self.reconnectDelay = reconnectDelay
    }

    /// Defensive -- every current caller (`SessionStore.removeSession`)
    /// already calls `stop()` explicitly before releasing its reference,
    /// but a future owner that doesn't should still get a real stop path
    /// (per docs/swift-practices.md: "every long-lived task ... needs ...
    /// a stop path") rather than relying on ARC to tear the connection down
    /// as a side effect of deallocation.
    deinit {
        connection?.cancel()
    }

    func start() {
        queue.async { [self] in
            guard isStopped else { return }
            isStopped = false
            reconnectAttempt = 0
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            generation += 1
            connection?.cancel()
            connection = nil
            receiveBuffer = Data()
        }
    }

    /// Reconnects with the full updated pane-id set -- a live connection
    /// can't be patched with a second `events.subscribe` (confirmed in the
    /// plan doc), so this always closes and reopens.
    func updatePaneIDs(_ paneIDs: Set<String>) {
        queue.async { [self] in
            subscribedPaneIDs = paneIDs
            guard !isStopped else { return }
            reconnectAttempt = 0
            connect()
        }
    }

    // MARK: Connection lifecycle (all below runs only on `queue`)

    private func subscribeRequestLine() -> String {
        var subscriptions: [[String: Any]] = [
            ["type": "pane.created"],
            ["type": "pane.closed"],
            ["type": "pane.agent_detected"],
        ]
        subscriptions += subscribedPaneIDs.sorted().map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        let request: [String: Any] = [
            "id": "vakta_sub",
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private func connect() {
        generation += 1
        let myGeneration = generation
        connection?.cancel()
        receiveBuffer = Data()

        let endpoint = NWEndpoint.unix(path: socketPath.path)
        let newConnection = NWConnection(to: endpoint, using: .tcp)
        connection = newConnection

        newConnection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleState(state, generation: myGeneration, connection: newConnection) }
        }
        newConnection.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State, generation myGeneration: Int, connection: NWConnection) {
        guard myGeneration == self.generation, !isStopped else { return }
        switch state {
        case .ready:
            reconnectAttempt = 0
            let request = subscribeRequestLine()
            connection.send(content: request.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.receiveLoop(generation: myGeneration, connection: connection) }
            })
        case .failed, .cancelled:
            scheduleReconnect(afterGeneration: myGeneration)
        default:
            break
        }
    }

    private func receiveLoop(generation myGeneration: Int, connection: NWConnection) {
        guard myGeneration == self.generation, !isStopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, myGeneration == self.generation, !self.isStopped else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    let (lines, remainder) = HerdrSocketDecoder.extractLines(from: self.receiveBuffer)
                    self.receiveBuffer = remainder
                    for line in lines {
                        self.handle(frame: HerdrSocketDecoder.decode(line: line))
                    }
                }
                if isComplete || error != nil {
                    self.scheduleReconnect(afterGeneration: myGeneration)
                } else {
                    self.receiveLoop(generation: myGeneration, connection: connection)
                }
            }
        }
    }

    private func handle(frame: HerdrSocketDecoder.Frame) {
        switch frame {
        case .subscriptionAck, .other:
            break
        case .paneEvent, .malformed:
            onTrigger?()
        }
    }

    private func scheduleReconnect(afterGeneration myGeneration: Int) {
        guard myGeneration == generation, !isStopped else { return }
        let delay = reconnectDelay(reconnectAttempt)
        reconnectAttempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, myGeneration == self.generation, !self.isStopped else { return }
            self.connect()
        }
    }
}
