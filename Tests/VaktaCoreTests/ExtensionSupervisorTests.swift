//
//  ExtensionSupervisorTests.swift
//  VaktaCoreTests
//
//  The Extension process lifecycle as (state, event) → (state, effects):
//  handshake, version check, crash backoff and the crash-loop limit,
//  stale timers, and shutdown.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class ExtensionSupervisorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let params = InitializeParams(
        apiVersion: vaktaExtensionAPIVersion,
        host: HostInfo(name: "Vakta", version: "test"),
        capabilities: HostCapabilities(viewKinds: [], effects: [])
    )

    private func supervisor(_ policy: ExtensionSupervisor.Policy = .init()) -> ExtensionSupervisor {
        ExtensionSupervisor(policy: policy, initialize: params)
    }

    private func initializeResult(id: Int, apiVersion: Int = vaktaExtensionAPIVersion) throws -> JSONRPCMessage {
        .response(id: .number(id), result: try ExtensionProtocolCodec.encode(InitializeResult(apiVersion: apiVersion, name: "Fixture")))
    }

    /// Drives a fresh supervisor to `.running` and returns it.
    private func running(_ policy: ExtensionSupervisor.Policy = .init()) throws -> ExtensionSupervisor {
        var machine = supervisor(policy)
        _ = machine.handle(.start)
        _ = machine.handle(.spawned)
        guard case .initializing(let id) = machine.phase else { XCTFail("not initializing"); return machine }
        _ = machine.handle(.received(try initializeResult(id: id)))
        XCTAssertEqual(machine.phase, .running)
        return machine
    }

    // MARK: - Handshake

    func test_start_spawns() {
        var machine = supervisor()
        XCTAssertEqual(machine.handle(.start), [.spawn])
        XCTAssertEqual(machine.phase, .starting)
    }

    func test_spawned_sendsInitialize_andArmsTheTimeout() throws {
        var machine = supervisor()
        _ = machine.handle(.start)

        let effects = machine.handle(.spawned)

        guard case .initializing(let id) = machine.phase else { return XCTFail("phase \(machine.phase)") }
        XCTAssertEqual(effects, [
            .send(.request(id: .number(id), method: ProtocolMethod.initialize, params: try ExtensionProtocolCodec.encode(params))),
            .schedule(.initializeTimeout, after: 10),
        ])
    }

    func test_matchingInitializeResult_isRunningAndReady() throws {
        var machine = supervisor()
        _ = machine.handle(.start)
        _ = machine.handle(.spawned)
        guard case .initializing(let id) = machine.phase else { return XCTFail() }

        XCTAssertEqual(machine.handle(.received(try initializeResult(id: id))), [.becameReady])
        XCTAssertEqual(machine.phase, .running)
    }

    func test_responseToAnotherID_whileInitializing_isIgnored() throws {
        var machine = supervisor()
        _ = machine.handle(.start)
        _ = machine.handle(.spawned)
        guard case .initializing(let id) = machine.phase else { return XCTFail() }

        XCTAssertEqual(machine.handle(.received(try initializeResult(id: id + 100))), [])
        XCTAssertEqual(machine.phase, .initializing(requestID: id))
    }

    func test_apiVersionMismatch_failsAndKills() throws {
        var machine = supervisor()
        _ = machine.handle(.start)
        _ = machine.handle(.spawned)
        guard case .initializing(let id) = machine.phase else { return XCTFail() }

        XCTAssertEqual(machine.handle(.received(try initializeResult(id: id, apiVersion: 2))), [.kill])
        XCTAssertEqual(machine.phase, .failed(.apiVersionMismatch(2)))
        XCTAssertEqual(machine.handle(.exited(code: 9, at: t0)), [], "the kill's exit must not count as a crash")
        XCTAssertEqual(machine.phase, .failed(.apiVersionMismatch(2)))
    }

    func test_rejectedOrUndecodableInitialize_fails() {
        var rejected = supervisor()
        _ = rejected.handle(.start)
        _ = rejected.handle(.spawned)
        guard case .initializing(let id) = rejected.phase else { return XCTFail() }
        XCTAssertEqual(rejected.handle(.received(.errorResponse(id: .number(id), error: JSONRPCError(code: -1, message: "no kata")))), [.kill])
        XCTAssertEqual(rejected.phase, .failed(.initializeRejected("no kata")))

        var garbled = supervisor()
        _ = garbled.handle(.start)
        _ = garbled.handle(.spawned)
        guard case .initializing(let other) = garbled.phase else { return XCTFail() }
        XCTAssertEqual(garbled.handle(.received(.response(id: .number(other), result: .string("hi")))), [.kill])
        XCTAssertEqual(garbled.phase, .failed(.invalidInitializeResult))
    }

    func test_spawnFailed_isFailed() {
        var machine = supervisor()
        _ = machine.handle(.start)
        XCTAssertEqual(machine.handle(.spawnFailed), [])
        XCTAssertEqual(machine.phase, .failed(.launchFailed))
    }

    func test_messagesBeforeTheHandshake_areNotDelivered() {
        var machine = supervisor()
        _ = machine.handle(.start)
        _ = machine.handle(.spawned)
        XCTAssertEqual(machine.handle(.received(.notification(method: ProtocolMethod.statusClear, params: nil))), [])
    }

    // MARK: - Running

    func test_running_deliversMessagesToTheHost() throws {
        var machine = try running()
        let message = JSONRPCMessage.notification(method: ProtocolMethod.log, params: .object(["level": .string("info"), "message": .string("hi")]))
        XCTAssertEqual(machine.handle(.received(message)), [.deliver(message)])
    }

    func test_requestIDs_neverRepeat() throws {
        var machine = try running()
        let first = machine.makeRequestID()
        let second = machine.makeRequestID()
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Crashes

    func test_crash_backsOffThenRespawns() throws {
        var machine = try running()

        XCTAssertEqual(machine.handle(.exited(code: 1, at: t0)), [.schedule(.backoff, after: 1)])
        XCTAssertEqual(machine.phase, .backingOff(attempt: 1))

        XCTAssertEqual(machine.handle(.timerFired(.backoff, at: t0.addingTimeInterval(1))), [.spawn])
        XCTAssertEqual(machine.phase, .starting)
    }

    func test_backoffDoubles_andIsCapped() {
        let policy = ExtensionSupervisor.Policy()
        XCTAssertEqual((1...7).map(policy.backoff(attempt:)), [1, 2, 4, 8, 16, 30, 30])
    }

    func test_crashLimitWithinWindow_isFailed() throws {
        var machine = try running()
        var policyAttempt = 0
        for offset in [0.0, 5, 10] {
            policyAttempt += 1
            let effects = machine.handle(.exited(code: 2, at: t0.addingTimeInterval(offset)))
            if policyAttempt < 3 {
                XCTAssertEqual(machine.phase, .backingOff(attempt: policyAttempt))
                XCTAssertEqual(effects, [.schedule(.backoff, after: machine.policy.backoff(attempt: policyAttempt))])
                _ = machine.handle(.timerFired(.backoff, at: t0.addingTimeInterval(offset + 1)))
                _ = machine.handle(.spawned)
                guard case .initializing(let id) = machine.phase else { return XCTFail() }
                _ = machine.handle(.received(try initializeResult(id: id)))
            } else {
                XCTAssertEqual(effects, [])
                XCTAssertEqual(machine.phase, .failed(.crashLoop(lastExitCode: 2)))
            }
        }
    }

    func test_crashesOutsideTheWindow_dontAccumulate() throws {
        var machine = try running()
        for offset in [0.0, 61, 122, 183] {
            _ = machine.handle(.exited(code: 1, at: t0.addingTimeInterval(offset)))
            XCTAssertEqual(machine.phase, .backingOff(attempt: 1), "offset \(offset)")
            _ = machine.handle(.timerFired(.backoff, at: t0.addingTimeInterval(offset + 1)))
            _ = machine.handle(.spawned)
            guard case .initializing(let id) = machine.phase else { return XCTFail() }
            _ = machine.handle(.received(try initializeResult(id: id)))
        }
    }

    func test_initializeTimeout_killsAndCountsAsACrash() {
        var machine = supervisor()
        _ = machine.handle(.start)
        _ = machine.handle(.spawned)

        XCTAssertEqual(machine.handle(.timerFired(.initializeTimeout, at: t0)), [.kill, .schedule(.backoff, after: 1)])
        XCTAssertEqual(machine.phase, .backingOff(attempt: 1))
        XCTAssertEqual(machine.handle(.exited(code: 15, at: t0)), [], "the kill's exit is already counted")
    }

    func test_staleTimers_areIgnored() throws {
        var machine = try running()
        XCTAssertEqual(machine.handle(.timerFired(.initializeTimeout, at: t0)), [])
        XCTAssertEqual(machine.handle(.timerFired(.backoff, at: t0)), [])
        XCTAssertEqual(machine.phase, .running)
    }

    func test_restart_fromFailed_clearsCrashHistory() throws {
        var machine = try running(.init(crashLimit: 1))
        _ = machine.handle(.exited(code: 1, at: t0))
        XCTAssertEqual(machine.phase, .failed(.crashLoop(lastExitCode: 1)))

        XCTAssertEqual(machine.handle(.restart), [.spawn])
        XCTAssertEqual(machine.phase, .starting)
        XCTAssertEqual(machine.crashTimes, [])
    }

    // MARK: - Shutdown

    func test_stop_whileRunning_sendsShutdown_thenStopsOnExit() throws {
        var machine = try running()

        let effects = machine.handle(.stop)

        XCTAssertEqual(machine.phase, .stopping)
        guard case .send(.request(_, let method, nil))? = effects.first else { return XCTFail("effects \(effects)") }
        XCTAssertEqual(method, ProtocolMethod.shutdown)
        XCTAssertEqual(Array(effects.dropFirst()), [.schedule(.shutdownGrace, after: 2)])

        XCTAssertEqual(machine.handle(.exited(code: 0, at: t0)), [])
        XCTAssertEqual(machine.phase, .stopped)
        XCTAssertEqual(machine.crashTimes, [], "a requested exit is not a crash")
    }

    func test_stop_thatOutlivesTheGrace_isKilled() throws {
        var machine = try running()
        _ = machine.handle(.stop)
        XCTAssertEqual(machine.handle(.timerFired(.shutdownGrace, at: t0)), [.kill])
        XCTAssertEqual(machine.phase, .stopping)
    }

    func test_stop_whileBackingOff_orFailed_isStoppedWithoutEffects() throws {
        var backingOff = try running()
        _ = backingOff.handle(.exited(code: 1, at: t0))
        XCTAssertEqual(backingOff.handle(.stop), [])
        XCTAssertEqual(backingOff.phase, .stopped)
        XCTAssertEqual(backingOff.handle(.timerFired(.backoff, at: t0)), [], "a stopped machine ignores its old backoff")

        var failed = supervisor()
        _ = failed.handle(.start)
        _ = failed.handle(.spawnFailed)
        XCTAssertEqual(failed.handle(.stop), [])
        XCTAssertEqual(failed.phase, .stopped)
    }

    func test_start_whileRunning_isANoOp() throws {
        var machine = try running()
        XCTAssertEqual(machine.handle(.start), [])
        XCTAssertEqual(machine.phase, .running)
    }
}
