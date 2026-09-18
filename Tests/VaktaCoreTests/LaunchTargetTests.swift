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

    // MARK: supportsWorkspaces

    func test_supportsWorkspaces_herdrProfile_isTrue() {
        let profile = Profile(name: "p", command: "herdr", arguments: "--session {name}")
        XCTAssertTrue(LaunchTargetResolver.supportsWorkspaces(profile, sessionName: "vakta-1"))
    }

    func test_supportsWorkspaces_tmuxProfile_isTrue() {
        // tmux windows are its workspace analogue (`vakta#43sg`) -- the
        // capability check lights up automatically once `workspaceListArgv`
        // vends tmux argv, with no `== .herdr` branch to update here.
        let profile = Profile(name: "p", command: "tmux", arguments: "new-session -A -s {name}")
        XCTAssertTrue(LaunchTargetResolver.supportsWorkspaces(profile, sessionName: "vakta-1"))
    }

    func test_supportsWorkspaces_plainShellProfile_isFalse() {
        XCTAssertFalse(LaunchTargetResolver.supportsWorkspaces(Profile.shell, sessionName: "vakta-1"))
    }

    func test_supportsWorkspaces_herdrRemoteProfile_isFalse() {
        // Unsupported for querying at all (`resolve` returns `.unsupported`),
        // so no workspace disclosure/switcher rows either.
        let profile = Profile(name: "p", command: "herdr", arguments: "--remote me@host --session {name}")
        XCTAssertFalse(LaunchTargetResolver.supportsWorkspaces(profile, sessionName: "vakta-1"))
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

    // MARK: workspaceListArgv / workspaceFocusArgv

    func test_workspaceListArgv_herdr() {
        let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(target.workspaceListArgv(sessionName: "foo"), ["herdr", "--session", "foo", "workspace", "list"])
    }

    func test_workspaceListArgv_tmux_defaultSocket() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(
            target.workspaceListArgv(sessionName: "foo"),
            ["tmux", "list-windows", "-t", "foo", "-F", "#{window_id}|#{window_name}|#{window_active}|#{@vakta_last_exit}"]
        )
    }

    func test_workspaceListArgv_tmux_customSocketPath() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: "/tmp/custom", environment: [:])
        XCTAssertEqual(
            target.workspaceListArgv(sessionName: "foo"),
            ["tmux", "-S", "/tmp/custom", "list-windows", "-t", "foo", "-F", "#{window_id}|#{window_name}|#{window_active}|#{@vakta_last_exit}"]
        )
    }

    func test_workspaceListArgv_tmux_customSocketName() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketName: "work", environment: [:])
        XCTAssertEqual(
            target.workspaceListArgv(sessionName: "foo"),
            ["tmux", "-L", "work", "list-windows", "-t", "foo", "-F", "#{window_id}|#{window_name}|#{window_active}|#{@vakta_last_exit}"]
        )
    }

    func test_workspaceFocusArgv_herdr() {
        let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(
            target.workspaceFocusArgv(sessionName: "foo", workspaceID: "ws-1"),
            ["herdr", "--session", "foo", "workspace", "focus", "ws-1"]
        )
    }

    func test_workspaceFocusArgv_tmux_defaultSocket() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: nil, environment: [:])
        XCTAssertEqual(
            target.workspaceFocusArgv(sessionName: "foo", workspaceID: "@1"),
            ["tmux", "select-window", "-t", "foo:@1"]
        )
    }

    func test_workspaceFocusArgv_tmux_customSocketPath() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: "/tmp/custom", environment: [:])
        XCTAssertEqual(
            target.workspaceFocusArgv(sessionName: "foo", workspaceID: "@1"),
            ["tmux", "-S", "/tmp/custom", "select-window", "-t", "foo:@1"]
        )
    }

    func test_setActiveWorkspaceCommandStatusArgv_tmux_setsTheCurrentWindowOption() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: "/tmp/custom", environment: [:])
        XCTAssertEqual(
            target.setActiveWorkspaceCommandStatusArgv(sessionName: "foo", exitCode: 7),
            ["tmux", "-S", "/tmp/custom", "set-window-option", "-t", "foo", "@vakta_last_exit", "7"]
        )
    }

    // MARK: eventStreamSocketPath

    func test_eventStreamSocketPath_herdr_resolvesUnderConfigDirectory() {
        let target = MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
        let configDirectory = URL(fileURLWithPath: "/tmp/herdr-config")
        XCTAssertEqual(
            target.eventStreamSocketPath(sessionName: "foo", configDirectory: configDirectory),
            HerdrSocketPath.resolve(sessionName: "foo", configDirectory: configDirectory)
        )
    }

    func test_eventStreamSocketPath_tmux_isNil() {
        let target = MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: nil, environment: [:])
        XCTAssertNil(target.eventStreamSocketPath(sessionName: "foo", configDirectory: URL(fileURLWithPath: "/tmp/herdr-config")))
    }

    // MARK: agentStatusPollOutcome

    func test_agentStatusPollOutcome_herdrProfile_isPollWithResolvedTarget() {
        let profile = Profile(name: "p", command: "herdr", arguments: "--session {name}")
        guard case .poll(let target) = LaunchTargetResolver.agentStatusPollOutcome(for: profile, sessionName: "foo") else {
            return XCTFail("expected .poll")
        }
        XCTAssertEqual(target.backend, .herdr)
    }

    func test_agentStatusPollOutcome_tmuxProfile_isSkip() {
        let profile = Profile(name: "p", command: "tmux", arguments: "new-session -A -s {name}")
        XCTAssertEqual(LaunchTargetResolver.agentStatusPollOutcome(for: profile, sessionName: "foo"), .skip)
    }

    func test_agentStatusPollOutcome_plainShellProfile_isSkip() {
        XCTAssertEqual(LaunchTargetResolver.agentStatusPollOutcome(for: Profile.shell, sessionName: "foo"), .skip)
    }

    func test_agentStatusPollOutcome_herdrRemoteProfile_isUnavailable() {
        let profile = Profile(name: "p", command: "herdr", arguments: "--remote me@host --session {name}")
        XCTAssertEqual(LaunchTargetResolver.agentStatusPollOutcome(for: profile, sessionName: "foo"), .unavailable)
    }
}
