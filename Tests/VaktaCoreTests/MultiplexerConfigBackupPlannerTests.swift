//
//  MultiplexerConfigBackupPlannerTests.swift
//  VaktaCoreTests
//
//  Which tmux/herdr config files to copy before the Mac-style shortcuts are
//  applied, what to call each copy, and the timestamped folder they go in.
//  Existence is supplied; nothing is read.

import XCTest
@testable import Vakta

final class MultiplexerConfigBackupPlannerTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/sam", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func plan(environment: [String: String] = [:], existing: Set<String>) -> MultiplexerConfigBackupPlan? {
        MultiplexerConfigBackupPlanner.plan(home: home, environment: environment, now: now, timeZone: utc, fileExists: existing.contains)
    }

    func test_everyExistingConfig_withDistinctNames_inATimestampedFolder() throws {
        let plan = try XCTUnwrap(plan(existing: [
            "/Users/sam/.tmux.conf",
            "/Users/sam/.config/tmux/tmux.conf",
            "/Users/sam/.config/herdr/config.toml",
        ]))

        XCTAssertEqual(plan.folderName, "mac-shortcuts-2026-09-21-141320")
        XCTAssertEqual(plan.files, [
            MultiplexerConfigBackupFile(source: "/Users/sam/.tmux.conf", name: "dot-tmux.conf"),
            MultiplexerConfigBackupFile(source: "/Users/sam/.config/tmux/tmux.conf", name: "tmux.conf"),
            MultiplexerConfigBackupFile(source: "/Users/sam/.config/herdr/config.toml", name: "herdr-config.toml"),
        ])
    }

    func test_missingConfigsAreSkipped() throws {
        let plan = try XCTUnwrap(plan(existing: ["/Users/sam/.config/herdr/config.toml"]))
        XCTAssertEqual(plan.files.map(\.name), ["herdr-config.toml"])
    }

    func test_nothingToBackUp_isNil() {
        XCTAssertNil(plan(existing: []))
    }

    func test_honoursXDGAndHerdrConfigPathOverrides() throws {
        let plan = try XCTUnwrap(plan(
            environment: ["XDG_CONFIG_HOME": "/Users/sam/xdg", "HERDR_CONFIG_PATH": "~/dotfiles/herdr.toml"],
            existing: ["/Users/sam/xdg/tmux/tmux.conf", "/Users/sam/dotfiles/herdr.toml", "/Users/sam/.config/tmux/tmux.conf"]
        ))
        XCTAssertEqual(plan.files.map(\.source), ["/Users/sam/xdg/tmux/tmux.conf", "/Users/sam/dotfiles/herdr.toml"])
    }
}
