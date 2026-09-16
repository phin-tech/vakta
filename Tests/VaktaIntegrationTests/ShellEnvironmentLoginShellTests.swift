//
//  ShellEnvironmentLoginShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `ShellEnvironment.loginShellPATH`/`resolvedPATH` and
//  `ResolvedPATH` -- previously untestable because the real login shell
//  (`ProcessInfo.processInfo.environment["SHELL"]`) was read directly inside
//  the decision function with no injection seam (docs/swift-practices.md:
//  "Supply ... shell/environment values ... rather than retrieving them
//  inside decision functions"). `shell:` is now an injectable parameter
//  (default unchanged); these tests point it at a real fixture executable
//  instead of the user's actual shell. Matches `LaunchTargetShellTests`'s
//  real-fixture-executable style -- no mocks. See testing.md's `mc9g` row.

import XCTest
@testable import Vakta

final class ShellEnvironmentLoginShellTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellEnvironmentLoginShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeShell(named name: String = "fake-shell.sh", script: String) throws -> String {
        let url = tempDirectory.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func test_loginShellPATH_realShellPrintingPATH_extractsIt() throws {
        let shell = try makeShell(script: """
        #!/bin/sh
        printf 'PATH=/from/fixture/bin:/usr/bin\\n'
        """)

        let result = ShellEnvironment.loginShellPATH(shell: shell, timeout: 4)

        XCTAssertEqual(result, "/from/fixture/bin:/usr/bin")
    }

    func test_loginShellPATH_shellExitsNonzero_isNil() throws {
        let shell = try makeShell(script: """
        #!/bin/sh
        exit 1
        """)

        XCTAssertNil(ShellEnvironment.loginShellPATH(shell: shell, timeout: 4))
    }

    func test_loginShellPATH_missingExecutable_isNil() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist").path

        XCTAssertNil(ShellEnvironment.loginShellPATH(shell: missing, timeout: 4))
    }

    func test_loginShellPATH_shellHangs_timesOutAndIsNil() throws {
        let shell = try makeShell(script: """
        #!/bin/sh
        sleep 30
        """)

        let start = Date()
        let result = ShellEnvironment.loginShellPATH(shell: shell, timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 5)
    }

    func test_resolvedPATH_usesInjectedShellsPATHWhenAvailable() throws {
        let shell = try makeShell(script: """
        #!/bin/sh
        printf 'PATH=/from/fixture/bin\\n'
        """)

        XCTAssertEqual(ShellEnvironment.resolvedPATH(timeout: 4, shell: shell), "/from/fixture/bin")
    }

    func test_resolvedPATH_shellFails_fallsBackToFallbackPATH() throws {
        let shell = try makeShell(script: """
        #!/bin/sh
        exit 1
        """)

        XCTAssertEqual(ShellEnvironment.resolvedPATH(timeout: 4, shell: shell), ShellEnvironment.fallbackPATH())
    }

    // MARK: ResolvedPATH

    func test_resolvedPATHClass_shellResolvesInTime_returnsRealValue() throws {
        let shell = try makeShell(script: """
        #!/bin/sh
        printf 'PATH=/from/fixture/bin\\n'
        """)

        let resolver = ResolvedPATH(timeout: 4, shell: shell)
        XCTAssertEqual(resolver.value(waitingUpTo: 4), "/from/fixture/bin")
    }

    func test_resolvedPATHClass_slowShell_boundedWaitFallsBack() throws {
        let shell = try makeShell(script: """
        #!/bin/sh
        sleep 5
        printf 'PATH=/too/late\\n'
        """)

        let resolver = ResolvedPATH(timeout: 10, shell: shell)
        let start = Date()
        let value = resolver.value(waitingUpTo: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(value, ShellEnvironment.fallbackPATH())
        XCTAssertLessThan(elapsed, 2)
    }
}
