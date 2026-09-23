//
//  AppVersionTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `AppVersion`: parsing the bundle's marketing
//  version (and the release tags' `v`-prefixed / prerelease forms), and the
//  semver ordering What's New uses to pick release notes.
//

import XCTest
@testable import Vakta

final class AppVersionTests: XCTestCase {
    private func version(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws -> AppVersion {
        try XCTUnwrap(AppVersion(string), "expected \(string) to parse", file: file, line: line)
    }

    func test_parsesMajorMinorPatch() throws {
        XCTAssertEqual(try version("1.2.3").description, "1.2.3")
    }

    func test_vPrefix_parsesToTheSameVersion() throws {
        XCTAssertEqual(try version("v1.2.3"), try version("1.2.3"))
    }

    func test_missingPatch_isZero() throws {
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertEqual(try version("1.2").description, "1.2.0")
    }

    func test_prerelease_isKeptInDescription() throws {
        XCTAssertEqual(try version("1.2.3-beta.1").description, "1.2.3-beta.1")
    }

    func test_invalidStrings_doNotParse() {
        for invalid in ["", "abc", "1", "1.x.3", "1.2.3.4", "-1.2.3", "1.2.3-", "$(MARKETING_VERSION)"] {
            XCTAssertNil(AppVersion(invalid), "\(invalid) should not parse")
        }
    }

    func test_ordering_isNumericNotLexical() throws {
        XCTAssertLessThan(try version("1.2.3"), try version("1.10.0"))
        XCTAssertLessThan(try version("0.9.9"), try version("1.0.0"))
        XCTAssertLessThan(try version("1.2.3"), try version("1.2.4"))
    }

    func test_prerelease_sortsBeforeItsRelease() throws {
        XCTAssertLessThan(try version("1.2.3-beta.1"), try version("1.2.3"))
        XCTAssertLessThan(try version("1.2.2"), try version("1.2.3-beta.1"))
    }

    func test_prereleaseIdentifiers_compareNumericallyWhenNumeric() throws {
        XCTAssertLessThan(try version("1.2.3-beta.2"), try version("1.2.3-beta.10"))
        XCTAssertLessThan(try version("1.2.3-alpha"), try version("1.2.3-beta"))
    }
}
