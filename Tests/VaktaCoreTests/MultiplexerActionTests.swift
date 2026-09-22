//
//  MultiplexerActionTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the mutating multiplexer actions (split, close,
//  zoom, resize, workspace create/rename/close) exposed to the sidebar
//  context menu and ⌘K: the argv each backend builds for a given
//  `MultiplexerAction`, and the capability gate the UI defers to. No process
//  execution -- see `MultiplexerCommandShellTests` for the shell round-trip.
//
//  Direction mapping and per-backend addressing live in `actionArgv`, so a
//  new backend answers the same table rather than teaching every call site a
//  new noun. Herdr addresses a pane/workspace by its opaque id positionally
//  (mirroring the already-shipping `workspace focus <id>`); tmux qualifies a
//  window as `<session>:<window>` and a pane by its own `%id`.

import XCTest
@testable import Vakta

final class MultiplexerActionTests: XCTestCase {
    private func herdr() -> MultiplexerTarget {
        MultiplexerTarget(backend: .herdr, executable: "herdr", tmuxSocketPath: nil, environment: [:])
    }

    private func tmux(socketPath: String? = nil, socketName: String? = nil) -> MultiplexerTarget {
        MultiplexerTarget(backend: .tmux, executable: "tmux", tmuxSocketPath: socketPath, tmuxSocketName: socketName, environment: [:])
    }

    // MARK: split

    func test_splitPane_right_herdr_focusesTheNewPane() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .splitPane(paneID: "w2C:p3", direction: .right)),
            ["herdr", "--session", "foo", "pane", "split", "--pane", "w2C:p3", "--direction", "right", "--focus"]
        )
    }

    func test_splitPane_down_herdr() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .splitPane(paneID: "w2C:p3", direction: .down)),
            ["herdr", "--session", "foo", "pane", "split", "--pane", "w2C:p3", "--direction", "down", "--focus"]
        )
    }

    func test_splitPane_right_tmux_isHorizontalSplit() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .splitPane(paneID: "%3", direction: .right)),
            ["tmux", "split-window", "-h", "-t", "%3"]
        )
    }

    func test_splitPane_down_tmux_isVerticalSplit() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .splitPane(paneID: "%3", direction: .down)),
            ["tmux", "split-window", "-v", "-t", "%3"]
        )
    }

    func test_splitPane_tmux_customSocketPath_isPassedThrough() {
        XCTAssertEqual(
            tmux(socketPath: "/tmp/custom").actionArgv(sessionName: "foo", .splitPane(paneID: "%3", direction: .right)),
            ["tmux", "-S", "/tmp/custom", "split-window", "-h", "-t", "%3"]
        )
    }

    // MARK: close pane

    func test_closePane_herdr_targetsPanePositionally() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .closePane(paneID: "w2C:p3")),
            ["herdr", "--session", "foo", "pane", "close", "w2C:p3"]
        )
    }

    func test_closePane_tmux_killsPane() {
        XCTAssertEqual(
            tmux(socketName: "work").actionArgv(sessionName: "foo", .closePane(paneID: "%3")),
            ["tmux", "-L", "work", "kill-pane", "-t", "%3"]
        )
    }

    // MARK: zoom pane

    func test_zoomPane_herdr_togglesByPaneID() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .zoomPane(paneID: "w2C:p3")),
            ["herdr", "--session", "foo", "pane", "zoom", "--pane", "w2C:p3"]
        )
    }

    func test_zoomPane_tmux_togglesResizeZoomFlag() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .zoomPane(paneID: "%3")),
            ["tmux", "resize-pane", "-Z", "-t", "%3"]
        )
    }

    // MARK: resize pane (intent-only; per-backend step and unit)

    func test_resizePane_left_herdr_usesFloatRatioStep() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .resizePane(paneID: "w2C:p3", direction: .left)),
            ["herdr", "--session", "foo", "pane", "resize", "--pane", "w2C:p3", "--direction", "left", "--amount", "0.05"]
        )
    }

    func test_resizePane_directions_tmux_mapToCellFlags() {
        let cases: [(ResizeDirection, String)] = [(.left, "-L"), (.right, "-R"), (.up, "-U"), (.down, "-D")]
        for (direction, flag) in cases {
            XCTAssertEqual(
                tmux().actionArgv(sessionName: "foo", .resizePane(paneID: "%3", direction: direction)),
                ["tmux", "resize-pane", "-t", "%3", flag, "5"],
                "direction \(direction)"
            )
        }
    }

    // MARK: close workspace

    func test_closeWorkspace_herdr_targetsWorkspacePositionally() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .closeWorkspace(workspaceID: "w2C")),
            ["herdr", "--session", "foo", "workspace", "close", "w2C"]
        )
    }

    func test_closeWorkspace_tmux_killsWindowQualifiedBySession() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .closeWorkspace(workspaceID: "@1")),
            ["tmux", "kill-window", "-t", "foo:@1"]
        )
    }

    // MARK: create workspace

    func test_createWorkspace_herdr_noLabel() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .createWorkspace(label: nil)),
            ["herdr", "--session", "foo", "workspace", "create"]
        )
    }

    func test_createWorkspace_herdr_withLabel_passesLabelAsData() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .createWorkspace(label: "build things")),
            ["herdr", "--session", "foo", "workspace", "create", "--label", "build things"]
        )
    }

    func test_createWorkspace_tmux_noLabel_newWindowInSession() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .createWorkspace(label: nil)),
            ["tmux", "new-window", "-t", "foo"]
        )
    }

    func test_createWorkspace_tmux_withLabel_namesTheWindow() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .createWorkspace(label: "build")),
            ["tmux", "new-window", "-t", "foo", "-n", "build"]
        )
    }

    // MARK: rename workspace

    func test_renameWorkspace_herdr_positionalIDThenName() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .renameWorkspace(workspaceID: "w2C", label: "guildhall")),
            ["herdr", "--session", "foo", "workspace", "rename", "w2C", "guildhall"]
        )
    }

    func test_renameWorkspace_tmux_renamesWindowQualifiedBySession() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .renameWorkspace(workspaceID: "@1", label: "guildhall")),
            ["tmux", "rename-window", "-t", "foo:@1", "guildhall"]
        )
    }

    // MARK: rename pane

    func test_renamePane_herdr_positionalPaneIDThenLabel() {
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .renamePane(paneID: "w2C:p3", label: "server")),
            ["herdr", "--session", "foo", "pane", "rename", "w2C:p3", "server"]
        )
    }

    func test_renamePane_tmux_setsPaneTitle() {
        XCTAssertEqual(
            tmux().actionArgv(sessionName: "foo", .renamePane(paneID: "%3", label: "server")),
            ["tmux", "select-pane", "-t", "%3", "-T", "server"]
        )
    }

    // MARK: stop session

    func test_stopSession_herdr_namesSessionPositionally_notViaGlobalFlag() {
        // `session stop <NAME>` names which session to stop -- it is not the
        // `--session <name>` addressing the other subcommands use to run
        // *inside* a session.
        XCTAssertEqual(
            herdr().actionArgv(sessionName: "foo", .stopSession),
            ["herdr", "session", "stop", "foo"]
        )
    }

    func test_stopSession_tmux_killsSession() {
        XCTAssertEqual(
            tmux(socketName: "work").actionArgv(sessionName: "foo", .stopSession),
            ["tmux", "-L", "work", "kill-session", "-t", "foo"]
        )
    }

    // MARK: supportsActions capability gate

    func test_supportsActions_herdrProfile_isTrue() {
        let profile = Profile(name: "p", command: "herdr", arguments: "--session {name}")
        XCTAssertTrue(LaunchTargetResolver.supportsActions(profile, sessionName: "vakta-1"))
    }

    func test_supportsActions_tmuxProfile_isTrue() {
        let profile = Profile(name: "p", command: "tmux", arguments: "new-session -A -s {name}")
        XCTAssertTrue(LaunchTargetResolver.supportsActions(profile, sessionName: "vakta-1"))
    }

    func test_supportsActions_plainShellProfile_isFalse() {
        XCTAssertFalse(LaunchTargetResolver.supportsActions(Profile.shell, sessionName: "vakta-1"))
    }

    func test_supportsActions_herdrRemoteProfile_isFalse() {
        let profile = Profile(name: "p", command: "herdr", arguments: "--remote me@host --session {name}")
        XCTAssertFalse(LaunchTargetResolver.supportsActions(profile, sessionName: "vakta-1"))
    }
}
