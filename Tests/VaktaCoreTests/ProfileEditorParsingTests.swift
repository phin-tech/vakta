//
//  ProfileEditorParsingTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `ProfileEditorParsing`: malformed lines must
//  produce a reportable error, not disappear silently.

import XCTest
@testable import Vakta

final class ProfileEditorParsingTests: XCTestCase {
    // MARK: parseEnvironment

    func test_parseEnvironment_validLines_areParsed() {
        let result = ProfileEditorParsing.parseEnvironment("FOO=bar\nBAZ=qux")
        XCTAssertEqual(result.entries, ["FOO": "bar", "BAZ": "qux"])
        XCTAssertEqual(result.errors, [])
    }

    func test_parseEnvironment_valueContainingEquals_isPreservedWhole() {
        let result = ProfileEditorParsing.parseEnvironment("URL=https://x?a=1&b=2")
        XCTAssertEqual(result.entries["URL"], "https://x?a=1&b=2")
    }

    func test_parseEnvironment_blankLines_areSkippedSilently() {
        let result = ProfileEditorParsing.parseEnvironment("FOO=bar\n\n   \nBAZ=qux")
        XCTAssertEqual(result.entries, ["FOO": "bar", "BAZ": "qux"])
        XCTAssertEqual(result.errors, [])
    }

    func test_parseEnvironment_lineMissingEquals_producesAnError() {
        let result = ProfileEditorParsing.parseEnvironment("NOT_KEY_VALUE")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func test_parseEnvironment_emptyKey_producesAnError() {
        let result = ProfileEditorParsing.parseEnvironment("=value")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func test_parseEnvironment_invalidKeyCharacters_producesAnError() {
        let result = ProfileEditorParsing.parseEnvironment("HAS SPACE=value")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func test_parseEnvironment_errorLineNumber_matchesItsPositionInTheText() {
        let result = ProfileEditorParsing.parseEnvironment("FOO=bar\nBROKEN\nBAZ=qux")
        XCTAssertEqual(result.errors.first?.contains("Line 2") ?? false, true, result.errors.first ?? "<none>")
    }

    // MARK: parseScrubKeys

    func test_parseScrubKeys_validNames_areParsed() {
        let (keys, errors) = ProfileEditorParsing.parseScrubKeys("HERDR_ENV\nTMUX")
        XCTAssertEqual(keys, ["HERDR_ENV", "TMUX"])
        XCTAssertEqual(errors, [])
    }

    func test_parseScrubKeys_blankLines_areSkippedSilently() {
        let (keys, errors) = ProfileEditorParsing.parseScrubKeys("HERDR_ENV\n\nTMUX\n")
        XCTAssertEqual(keys, ["HERDR_ENV", "TMUX"])
        XCTAssertEqual(errors, [])
    }

    func test_parseScrubKeys_invalidName_producesAnError() {
        let (keys, errors) = ProfileEditorParsing.parseScrubKeys("HERDR_ENV; touch pwned")
        XCTAssertEqual(keys, [])
        XCTAssertEqual(errors.count, 1)
    }
}
