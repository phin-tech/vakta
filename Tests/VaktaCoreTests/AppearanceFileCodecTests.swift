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

    func test_decode_fileWithoutSidebarFontSize_keepsItsValuesAndDefaultsTheSizeToMatchTerminal() {
        // A file written before `sidebarFontSize` existed. It must still
        // decode -- not read as corrupt and lose the user's theme/style --
        // with the size at `0`, the "follow the terminal's size" sentinel.
        let data = Data(#"{"appearance":"dark","sidebarFont":"matchTerminal"}"#.utf8)
        XCTAssertEqual(
            codec.decode(data),
            AppearanceSettings(appearance: .dark, sidebarFont: .matchTerminal, sidebarFontSize: 0)
        )
    }

    func test_encode_thenDecode_roundTripsAnExplicitSidebarFontSize() throws {
        let settings = AppearanceSettings(appearance: .light, sidebarFont: .matchTerminal, sidebarFontSize: 15)
        let data = try XCTUnwrap(codec.encode(settings))
        XCTAssertEqual(codec.decode(data)?.sidebarFontSize, 15)
    }

    func test_decode_outOfRangeSidebarFontSize_isKeptRatherThanRejectingTheFile() {
        // Clamped at use (`SidebarRowFontResolver`), like the sidebar width:
        // one bad number must not cost the user the rest of the file.
        let data = Data(#"{"appearance":"dark","sidebarFont":"matchTerminal","sidebarFontSize":100000}"#.utf8)
        XCTAssertEqual(codec.decode(data)?.appearance, .dark)
        XCTAssertEqual(codec.decode(data)?.sidebarFontSize, 100000)
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
