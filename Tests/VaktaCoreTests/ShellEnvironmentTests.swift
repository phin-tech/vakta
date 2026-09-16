//
//  ShellEnvironmentTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `ShellEnvironment`'s pure PATH extraction and
//  fallback, with no process execution.

import XCTest
@testable import Vakta

final class ShellEnvironmentTests: XCTestCase {
    func test_extractPATH_findsThePATHLine() {
        let output = "HOME=/Users/me\nPATH=/usr/bin:/bin\nSHELL=/bin/zsh\n"
        XCTAssertEqual(ShellEnvironment.extractPATH(from: output), "/usr/bin:/bin")
    }

    func test_extractPATH_noPATHLine_isNil() {
        XCTAssertNil(ShellEnvironment.extractPATH(from: "HOME=/Users/me\nSHELL=/bin/zsh\n"))
    }

    func test_extractPATH_emptyPATHValue_isNil() {
        XCTAssertNil(ShellEnvironment.extractPATH(from: "PATH=\n"))
    }

    func test_extractPATH_emptyOutput_isNil() {
        XCTAssertNil(ShellEnvironment.extractPATH(from: ""))
    }

    func test_fallbackPATH_includesCommonToolDirectories() {
        let path = ShellEnvironment.fallbackPATH(home: "/Users/fixture")
        let components = path.split(separator: ":").map(String.init)
        XCTAssertTrue(components.contains("/usr/bin"))
        XCTAssertTrue(components.contains("/opt/homebrew/bin"))
        XCTAssertTrue(components.contains("/Users/fixture/.local/bin"))
    }
}
