//
//  AppearanceFileCodecTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `AppearanceFileCodec`: decode/migration from
//  raw bytes to `AppearanceSettings`, with no file I/O.

import XCTest
@testable import Vakta

final class AppearanceFileCodecTests: XCTestCase {
    private let codec = AppearanceFileCodec()

    func test_decode_currentShape_succeeds() throws {
        let settings = AppearanceSettings(appearance: .dark, sidebarFont: .matchTerminal)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(codec.decode(data), settings)
    }

    func test_decode_legacyBareAppearance_migratesWithDefaultSidebarFont() throws {
        let data = try JSONEncoder().encode(AppAppearance.dark)
        XCTAssertEqual(codec.decode(data), AppearanceSettings(appearance: .dark, sidebarFont: .system))
    }

    func test_decode_malformedJSON_returnsNil() {
        XCTAssertNil(codec.decode(Data("not json {".utf8)))
    }

    func test_encode_thenDecode_roundTrips() throws {
        let settings = AppearanceSettings(appearance: .light, sidebarFont: .matchTerminal)
        let data = try XCTUnwrap(codec.encode(settings))
        XCTAssertEqual(codec.decode(data), settings)
    }
}
