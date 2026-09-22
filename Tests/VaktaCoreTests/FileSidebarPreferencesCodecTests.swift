//
//  FileSidebarPreferencesCodecTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `FileSidebarPreferences` decoding/migration and
//  width clamping -- old files (missing fields) default sensibly, and an
//  extreme width is clamped at use rather than rejecting the file.
//

import XCTest
@testable import Vakta

final class FileSidebarPreferencesCodecTests: XCTestCase {
    private func decode(_ json: String) throws -> FileSidebarPreferences {
        try JSONDecoder().decode(FileSidebarPreferences.self, from: Data(json.utf8))
    }

    func test_emptyObject_defaultsToHiddenAtDefaultWidth() throws {
        let prefs = try decode("{}")
        XCTAssertEqual(prefs, FileSidebarPreferences(isVisible: false, width: 260))
    }

    func test_missingWidth_keepsDefaultWidth() throws {
        let prefs = try decode(#"{"isVisible": true}"#)
        XCTAssertTrue(prefs.isVisible)
        XCTAssertEqual(prefs.width, 260)
    }

    func test_roundTrips() throws {
        let original = FileSidebarPreferences(isVisible: true, width: 320)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(FileSidebarPreferences.self, from: data), original)
    }

    func test_extremeWidth_isDecodedButClampedAtUse() throws {
        let tooWide = try decode(#"{"width": 5000}"#)
        XCTAssertEqual(tooWide.width, 5000, "the raw value is preserved on decode")
        XCTAssertEqual(tooWide.clampedWidth, FileSidebarPreferences.maximumWidth)

        let tooNarrow = try decode(#"{"width": 10}"#)
        XCTAssertEqual(tooNarrow.clampedWidth, FileSidebarPreferences.minimumWidth)
    }

    func test_nonFiniteWidth_clampsToDefault() {
        XCTAssertEqual(FileSidebarPreferences(width: .nan).clampedWidth, 260)
    }
}
