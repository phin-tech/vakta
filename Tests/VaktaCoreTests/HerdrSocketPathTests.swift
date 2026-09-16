//
//  HerdrSocketPathTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrSocketPath.resolve`, which replicates
//  herdr's own CLI socket resolution for the one case Vakta actually uses
//  (an explicit `--session <name>`) -- confirmed by direct probe against a
//  real running herdr server: `--session default` resolves to the root
//  socket, not `sessions/default/herdr.sock`, and an explicit `--session`
//  wins over `HERDR_SOCKET_PATH` entirely (see docs/herdr-events-plan.md).

import XCTest
@testable import Vakta

final class HerdrSocketPathTests: XCTestCase {
    private let configDirectory = URL(fileURLWithPath: "/fixture/config/herdr", isDirectory: true)

    func test_defaultSessionName_resolvesToTheRootSocket() {
        let resolved = HerdrSocketPath.resolve(sessionName: "default", configDirectory: configDirectory)

        XCTAssertEqual(resolved.path, "/fixture/config/herdr/herdr.sock")
    }

    func test_namedSession_resolvesToItsOwnSessionSocket() {
        let resolved = HerdrSocketPath.resolve(sessionName: "vakta-12b216b9", configDirectory: configDirectory)

        XCTAssertEqual(resolved.path, "/fixture/config/herdr/sessions/vakta-12b216b9/herdr.sock")
    }

    func test_differentNamedSessions_resolveToDistinctSockets() {
        let a = HerdrSocketPath.resolve(sessionName: "session-a", configDirectory: configDirectory)
        let b = HerdrSocketPath.resolve(sessionName: "session-b", configDirectory: configDirectory)

        XCTAssertNotEqual(a, b)
    }
}
