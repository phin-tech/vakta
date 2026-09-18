//
//  WorkingDirectoryResolutionTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `WorkingDirectoryResolver.resolve`: which of the
//  three cwd signals "Open in Editor" trusts, in order --
//  1. a multiplexer's active-pane query (`ActivePaneWorkingDirectoryResult`),
//  2. OSC-7's `viewState.workingDirectory` (already wired, previously
//     unread -- see `GhosttyTerminal`'s `TerminalSurfacePwdDelegate`),
//  3. the profile's launch-time `workingDirectory` (stale after a `cd`, only
//     meaningful for a plain, non-multiplexer shell).
//  Pure: operates on a plain snapshot, no `Session`/`Profile`/`SessionStore`
//  dependency, so a session closing mid-query is the caller's concern (see
//  plan item 5's generation guard), not this function's.
//
//  RED: `WorkingDirectoryResolver` does not exist yet -- this file will not
//  compile until it's declared.

import XCTest
@testable import Vakta

final class WorkingDirectoryResolutionTests: XCTestCase {
    func test_multiplexerWorkingDirectory_windsOverEverythingElse() {
        XCTAssertEqual(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: .workingDirectory("/from/multiplexer"),
                terminalReportedWorkingDirectory: "/from/osc7",
                profileWorkingDirectory: "/from/profile"
            ),
            "/from/multiplexer"
        )
    }

    func test_multiplexerServerNotRunning_fallsBackToOSC7() {
        XCTAssertEqual(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: .serverNotRunning,
                terminalReportedWorkingDirectory: "/from/osc7",
                profileWorkingDirectory: "/from/profile"
            ),
            "/from/osc7"
        )
    }

    func test_multiplexerError_fallsBackToOSC7() {
        XCTAssertEqual(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: .error(code: "no_current_pane"),
                terminalReportedWorkingDirectory: "/from/osc7",
                profileWorkingDirectory: "/from/profile"
            ),
            "/from/osc7"
        )
    }

    func test_multiplexerMalformed_fallsBackToOSC7() {
        XCTAssertEqual(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: .malformed,
                terminalReportedWorkingDirectory: "/from/osc7",
                profileWorkingDirectory: "/from/profile"
            ),
            "/from/osc7"
        )
    }

    func test_noMultiplexerCapability_fallsBackToOSC7() {
        // A plain-shell profile, or a backend with no equivalent -- the
        // caller passes nil rather than attempting the query.
        XCTAssertEqual(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: nil,
                terminalReportedWorkingDirectory: "/from/osc7",
                profileWorkingDirectory: "/from/profile"
            ),
            "/from/osc7"
        )
    }

    func test_noMultiplexerAndNoOSC7_fallsBackToProfileLaunchDirectory() {
        XCTAssertEqual(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: nil,
                terminalReportedWorkingDirectory: nil,
                profileWorkingDirectory: "/from/profile"
            ),
            "/from/profile"
        )
    }

    func test_nothingKnown_isNil() {
        XCTAssertNil(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: nil,
                terminalReportedWorkingDirectory: nil,
                profileWorkingDirectory: nil
            )
        )
    }

    func test_emptyOSC7String_isTreatedAsUnknown_notALiteralPath() {
        // libghostty reports an empty string before its first OSC-7 sequence
        // -- must fall through to the profile default, not be treated as "".
        XCTAssertEqual(
            WorkingDirectoryResolver.resolve(
                multiplexerResult: nil,
                terminalReportedWorkingDirectory: "",
                profileWorkingDirectory: "/from/profile"
            ),
            "/from/profile"
        )
    }
}
