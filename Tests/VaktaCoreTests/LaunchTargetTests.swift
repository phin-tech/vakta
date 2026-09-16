//
//  LaunchTargetTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `LaunchTargetResolver`: target resolution and
//  the argv it builds, with no process execution.

import XCTest
@testable import Vakta

final class LaunchTargetTests: XCTestCase {
    // MARK: resolve

    func test_resolve_herdrProfile_isMultiplexerWithItsExecutableAndEnvironment() {
        let profile = Profile(
            name: "p",
            command: "/opt/custom/herdr",
            arguments: "--session {name}",
            environment: ["HERDR_SOCKET_PATH": "/tmp/custom.sock"]
        )
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(profile) else {
            return XCTFail("expected a multiplexer target")
        }
        XCTAssertEqual(target.backend, .herdr)
        XCTAssertEqual(target.executable, "/opt/custom/herdr")
        XCTAssertEqual(target.environment, ["HERDR_SOCKET_PATH": "/tmp/custom.sock"])
        XCTAssertNil(target.tmuxSocketPath)
    }

    func test_resolve_tmuxProfile_capturesCustomSocketPath() {
        let profile = Profile(name: "p", command: "tmux", arguments: "-S /tmp/custom -s {name} new-session -A -s {name}")
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(profile) else {
            return XCTFail("expected a multiplexer target")
        }
        XCTAssertEqual(target.backend, .tmux)
        XCTAssertEqual(target.tmuxSocketPath, "/tmp/custom")
    }

    func test_resolve_tmuxProfile_socketNameFlag_isCaptured() {
        let profile = Profile(name: "p", command: "tmux", arguments: "-L work new-session -A -s {name}")
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(profile) else {
            return XCTFail("expected a multiplexer target")
        }
        XCTAssertEqual(target.tmuxSocketName, "work")
        XCTAssertNil(target.tmuxSocketPath)
    }

    func test_resolve_tmuxProfile_noSocketFlag_hasNoSocketPath() {
        let profile = Profile(name: "p", command: "tmux", arguments: "new-session -A -s {name}")
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(profile) else {
            return XCTFail("expected a multiplexer target")
        }
        XCTAssertNil(target.tmuxSocketPath)
    }

    func test_resolve_herdrRemoteProfile_isUnsupported() {
        let profile = Profile(name: "p", command: "herdr", arguments: "--remote me@host --session {name}")
        XCTAssertEqual(LaunchTargetResolver.resolve(profile), .unsupported)
    }

    func test_resolve_plainShellProfile_isUnsupported() {
        XCTAssertEqual(LaunchTargetResolver.resolve(Profile.shell), .unsupported)
    }

    func test_resolve_absoluteExecutablePath_stillRecognizedByBasename() {
        let profile = Profile(name: "p", command: "/usr/local/bin/herdr", arguments: "--session {name}")
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(profile) else {
            return XCTFail("expected a multiplexer target")
        }
        XCTAssertEqual(target.backend, .herdr)
        XCTAssertEqual(target.executable, "/usr/local/bin/herdr")
    }

    func test_resolve_sameCommandAndArguments_producesEqualTargets() {
        let a = Profile(name: "a", command: "herdr", arguments: "--session {name}")
        let b = Profile(name: "b", command: "herdr", arguments: "--session {name}")
        XCTAssertEqual(LaunchTargetResolver.resolve(a), LaunchTargetResolver.resolve(b))
    }

    func test_resolve_differentSocketPaths_produceUnequalTargets() {
        let a = Profile(name: "a", command: "tmux", arguments: "-S /tmp/one new-session -A -s {name}")
        let b = Profile(name: "b", command: "tmux", arguments: "-S /tmp/two new-session -A -s {name}")
        XCTAssertNotEqual(LaunchTargetResolver.resolve(a), LaunchTargetResolver.resolve(b))
    }

    // MARK: isKnownMultiplexerCommand

    func test_isKnownMultiplexerCommand_herdrAndTmux_areTrue() {
        XCTAssertTrue(LaunchTargetResolver.isKnownMultiplexerCommand(Profile(name: "p", command: "herdr")))
        XCTAssertTrue(LaunchTargetResolver.isKnownMultiplexerCommand(Profile(name: "p", command: "tmux")))
    }

    func test_isKnownMultiplexerCommand_herdrRemote_isStillTrue() {
        // Unsupported for *querying*, but still a known multiplexer command
        // -- distinct from a plain shell, which is neither.
        let profile = Profile(name: "p", command: "herdr", arguments: "--remote me@host --session {name}")
        XCTAssertTrue(LaunchTargetResolver.isKnownMultiplexerCommand(profile))
    }

    func test_isKnownMultiplexerCommand_plainShell_isFalse() {
        XCTAssertFalse(LaunchTargetResolver.isKnownMultiplexerCommand(Profile.shell))
    }

    // MARK: argv construction

    func test_discoveryArgv_herdr() {
        let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(target.discoveryArgv, ["herdr", "session", "list"])
    }

    func test_discoveryArgv_tmux_defaultSocket() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(target.discoveryArgv, ["tmux", "list-sessions", "-F", "#{session_name}"])
    }

    func test_discoveryArgv_tmux_customSocketPath() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: "/tmp/custom", environment: [:])
        XCTAssertEqual(target.discoveryArgv, ["tmux", "-S", "/tmp/custom", "list-sessions", "-F", "#{session_name}"])
    }

    func test_discoveryArgv_tmux_customSocketName() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketName: "work", environment: [:])
        XCTAssertEqual(target.discoveryArgv, ["tmux", "-L", "work", "list-sessions", "-F", "#{session_name}"])
    }

    func test_statusArgv_herdr() {
        let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(target.statusArgv(sessionName: "foo"), ["herdr", "--session", "foo", "agent", "list"])
    }

    func test_statusArgv_tmux_isNil() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: nil, environment: [:])
        XCTAssertNil(target.statusArgv(sessionName: "foo"))
    }
}
