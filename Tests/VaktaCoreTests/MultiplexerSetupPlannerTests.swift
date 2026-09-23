//
//  MultiplexerSetupPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the tour's "install herdr and tmux" step:
//  finding an executable on a PATH value, choosing each tool's install
//  status/command from what's installed, and the transient installer
//  session's profile.
//

import XCTest
@testable import Vakta

final class MultiplexerSetupPlannerTests: XCTestCase {
    // MARK: Executable search

    func test_search_returnsTheFirstDirectoryThatHasIt() {
        let executables: Set = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        XCTAssertEqual(
            ExecutableSearch.firstMatch(named: "tmux", inPATH: "/usr/bin:/opt/homebrew/bin:/usr/local/bin", isExecutable: executables.contains),
            "/opt/homebrew/bin/tmux"
        )
    }

    func test_search_skipsEmptyAndRelativeEntries() {
        let executables: Set = ["tmux", "./tmux", "/bin/tmux"]
        XCTAssertEqual(
            ExecutableSearch.firstMatch(named: "tmux", inPATH: "::.:relative:/bin", isExecutable: executables.contains),
            "/bin/tmux"
        )
    }

    func test_search_trailingSlashDirectory_joinsCleanly() {
        XCTAssertEqual(
            ExecutableSearch.firstMatch(named: "herdr", inPATH: "/x/bin/", isExecutable: { $0 == "/x/bin/herdr" }),
            "/x/bin/herdr"
        )
    }

    func test_search_notFound_orEmptyPATH_isNil() {
        XCTAssertNil(ExecutableSearch.firstMatch(named: "herdr", inPATH: "/usr/bin:/bin", isExecutable: { _ in false }))
        XCTAssertNil(ExecutableSearch.firstMatch(named: "herdr", inPATH: "", isExecutable: { _ in true }))
    }

    // MARK: Install status

    func test_installedTool_reportsItsPath_regardlessOfHomebrew() {
        XCTAssertEqual(
            MultiplexerSetupPlanner.status(for: .herdr, toolPath: "/Users/me/.local/bin/herdr", brewPath: nil),
            .installed(path: "/Users/me/.local/bin/herdr")
        )
        XCTAssertEqual(
            MultiplexerSetupPlanner.status(for: .tmux, toolPath: "/opt/homebrew/bin/tmux", brewPath: "/opt/homebrew/bin/brew"),
            .installed(path: "/opt/homebrew/bin/tmux")
        )
    }

    func test_herdr_withHomebrew_installsWithBrew() {
        XCTAssertEqual(
            MultiplexerSetupPlanner.status(for: .herdr, toolPath: nil, brewPath: "/opt/homebrew/bin/brew"),
            .installable(command: "brew install herdr")
        )
    }

    func test_herdr_withoutHomebrew_usesTheOfficialInstallScript() {
        XCTAssertEqual(
            MultiplexerSetupPlanner.status(for: .herdr, toolPath: nil, brewPath: nil),
            .installable(command: "curl -fsSL https://herdr.dev/install.sh | sh")
        )
    }

    func test_tmux_withHomebrew_installsWithBrew() {
        XCTAssertEqual(
            MultiplexerSetupPlanner.status(for: .tmux, toolPath: nil, brewPath: "/usr/local/bin/brew"),
            .installable(command: "brew install tmux")
        )
    }

    func test_tmux_withoutHomebrew_needsHomebrewFirst() {
        XCTAssertEqual(MultiplexerSetupPlanner.status(for: .tmux, toolPath: nil, brewPath: nil), .needsHomebrew)
    }

    func test_tools_areHerdrThenTmux_withTheirExecutableNames() {
        XCTAssertEqual(MultiplexerTool.allCases, [.herdr, .tmux])
        XCTAssertEqual(MultiplexerTool.allCases.map(\.executableName), ["herdr", "tmux"])
    }

    // MARK: Installer session

    func test_installerProfile_runsTheScriptThroughBinSh_asOneQuotedArgument() {
        let id = UUID()
        let profile = MultiplexerSetupPlanner.installerProfile(for: .herdr, installCommand: "brew install herdr", id: id)

        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.name, "Install herdr")
        XCTAssertEqual(profile.command, "/bin/sh")
        XCTAssertTrue(profile.arguments.hasPrefix("-c '"), profile.arguments)
        XCTAssertTrue(profile.arguments.hasSuffix("'"), profile.arguments)
        XCTAssertTrue(profile.arguments.contains("brew install herdr"))
        XCTAssertFalse(profile.arguments.contains("{name}"), "an installer never reattaches a named session")
        XCTAssertTrue(profile.scrubbedEnvironmentKeys.isEmpty)
    }

    func test_installerProfile_quotesAnInstallCommandContainingSingleQuotes() {
        let profile = MultiplexerSetupPlanner.installerProfile(for: .tmux, installCommand: "echo 'hi'", id: UUID())
        XCTAssertTrue(profile.arguments.contains(#"echo '\''hi'\''"#), profile.arguments)
    }

    // MARK: Tour placement

    func test_tour_offersSetupRightAfterWelcome() {
        let steps = TutorialContent.steps(bindings: [], leader: LeaderSettings(), leaderSequences: [:])
        XCTAssertEqual(steps.prefix(2).map(\.id), [.welcome, .multiplexerSetup])
    }
}
