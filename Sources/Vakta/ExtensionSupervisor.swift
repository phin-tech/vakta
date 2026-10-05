//
//  ExtensionSupervisor.swift
//  Vakta
//
//  Pure lifecycle of one Extension process: spawn, initialize handshake,
//  restart with backoff after a crash, give up after repeated crashes, and
//  graceful shutdown. Time arrives in events; effects say what the shell must
//  do (spawn, send, kill, schedule a timer). See docs/extensions-plan.md.

import Foundation
import VaktaExtensionKit

struct ExtensionSupervisor: Equatable {
    struct Policy: Equatable {
        var initializeTimeout: TimeInterval = 10
        var shutdownGrace: TimeInterval = 2
        /// This many crashes within `crashWindow` marks the Extension Failed.
        var crashLimit = 3
        var crashWindow: TimeInterval = 60
        /// Delay before restart attempt `n` (1-based): 1s, 2s, 4s … capped.
        var backoffBase: TimeInterval = 1
        var backoffCap: TimeInterval = 30

        func backoff(attempt: Int) -> TimeInterval {
            min(backoffCap, backoffBase * pow(2, Double(max(0, attempt - 1))))
        }
    }

    enum FailureReason: Equatable {
        case launchFailed
        case crashLoop(lastExitCode: Int32?)
        case apiVersionMismatch(Int)
        case initializeRejected(String)
        case invalidInitializeResult
    }

    enum Phase: Equatable {
        case stopped
        case starting
        case initializing(requestID: Int)
        case running
        case backingOff(attempt: Int)
        case stopping
        case failed(FailureReason)
    }

    enum Timer: Equatable {
        case initializeTimeout
        case backoff
        case shutdownGrace
    }

    enum Event: Equatable {
        case start
        /// User-requested restart: clears crash history, works from Failed.
        case restart
        case stop
        case spawned
        case spawnFailed
        case received(JSONRPCMessage)
        case exited(code: Int32?, at: Date)
        case timerFired(Timer, at: Date)
    }

    enum Effect: Equatable {
        case spawn
        case send(JSONRPCMessage)
        case kill
        case schedule(Timer, after: TimeInterval)
        /// The handshake finished; the host may now send contexts.
        case becameReady
        /// A message for the host to route (view updates, status, log …).
        case deliver(JSONRPCMessage)
    }

    let policy: Policy
    let initialize: InitializeParams
    private(set) var phase: Phase = .stopped
    private(set) var crashTimes: [Date] = []
    private var nextRequestID = 1

    init(policy: Policy = Policy(), initialize: InitializeParams) {
        self.policy = policy
        self.initialize = initialize
    }

    /// Requests sent by the host need ids that never collide with the
    /// supervisor's own (`initialize`, `shutdown`).
    mutating func makeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.stopped, .start), (.failed, .start):
            phase = .starting
            return [.spawn]
        case (_, .restart):
            guard phase == .stopped || isFailed || isBackingOff else { return [] }
            crashTimes = []
            phase = .starting
            return [.spawn]

        case (.starting, .spawned):
            let id = makeRequestID()
            phase = .initializing(requestID: id)
            let params = (try? ExtensionProtocolCodec.encode(initialize)) ?? .null
            return [
                .send(.request(id: .number(id), method: ProtocolMethod.initialize, params: params)),
                .schedule(.initializeTimeout, after: policy.initializeTimeout),
            ]
        case (.starting, .spawnFailed):
            phase = .failed(.launchFailed)
            return []

        case (.initializing(let id), .received(let message)):
            return handshake(message, requestID: id)
        case (.initializing, .timerFired(.initializeTimeout, let now)):
            return [.kill] + crashed(exitCode: nil, at: now)

        case (.running, .received(let message)):
            return [.deliver(message)]

        case (.initializing, .exited(let code, let now)), (.running, .exited(let code, let now)):
            return crashed(exitCode: code, at: now)

        case (.backingOff, .timerFired(.backoff, _)):
            phase = .starting
            return [.spawn]

        case (.starting, .stop), (.initializing, .stop), (.running, .stop):
            phase = .stopping
            let id = makeRequestID()
            return [
                .send(.request(id: .number(id), method: ProtocolMethod.shutdown, params: nil)),
                .schedule(.shutdownGrace, after: policy.shutdownGrace),
            ]
        case (.backingOff, .stop), (.failed, .stop):
            phase = .stopped
            return []
        case (.stopping, .timerFired(.shutdownGrace, _)):
            return [.kill]
        case (.stopping, .exited):
            phase = .stopped
            return []

        default:
            // Stale timers, exits of processes already accounted for, and
            // messages outside the handshake or running phase.
            return []
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var isBackingOff: Bool {
        if case .backingOff = phase { return true }
        return false
    }

    private mutating func handshake(_ message: JSONRPCMessage, requestID: Int) -> [Effect] {
        switch message {
        case .response(.number(requestID), let result):
            guard let decoded = try? ExtensionProtocolCodec.decode(InitializeResult.self, from: result) else {
                phase = .failed(.invalidInitializeResult)
                return [.kill]
            }
            guard decoded.apiVersion == initialize.apiVersion else {
                phase = .failed(.apiVersionMismatch(decoded.apiVersion))
                return [.kill]
            }
            phase = .running
            return [.becameReady]
        case .errorResponse(.number(requestID)?, let error):
            phase = .failed(.initializeRejected(error.message))
            return [.kill]
        default:
            return []
        }
    }

    private mutating func crashed(exitCode: Int32?, at now: Date) -> [Effect] {
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < policy.crashWindow } + [now]
        guard crashTimes.count < policy.crashLimit else {
            phase = .failed(.crashLoop(lastExitCode: exitCode))
            return []
        }
        // The attempt is the number of recent crashes, so an Extension that
        // keeps crashing right after starting backs off further each time.
        let attempt = crashTimes.count
        phase = .backingOff(attempt: attempt)
        return [.schedule(.backoff, after: policy.backoff(attempt: attempt))]
    }
}
