//
//  SidebarSettingsCodecTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the sidebar-settings value type and its file
//  codec. `sidebar.json` grew from a bare `SidebarCollapseStyle` string into
//  a `SidebarSettings` struct that also remembers whether the sidebar was
//  collapsed and its expanded width, so the codec must migrate the legacy
//  shape (mirroring `KeybindingFileCodec`) and default fields a partial or
//  older file omits. An out-of-range width decodes successfully -- it is
//  clamped where it is used (see `SidebarWidthCapture`), never treated as a
//  corrupt file that would strand launch.

import XCTest
@testable import Vakta

final class SidebarSettingsCodecTests: XCTestCase {
    private let codec = SidebarSettingsFileCodec()

    // MARK: New struct shape

    func test_newStructShape_roundTripsEveryField() {
        let settings = SidebarSettings(collapseStyle: .hidden, isCollapsed: true, expandedWidth: 314)
        guard let data = codec.encode(settings) else {
            return XCTFail("encoding the settings struct must succeed")
        }
        XCTAssertEqual(codec.decode(data), settings)
    }

    // MARK: Legacy migration

    func test_legacyBareStyleString_migratesToStructWithDefaults() {
        // Exactly what the previous `JSONCodec<SidebarCollapseStyle>` wrote.
        let legacy = try! JSONEncoder().encode(SidebarCollapseStyle.hidden)

        let decoded = codec.decode(legacy)

        XCTAssertEqual(
            decoded,
            SidebarSettings(collapseStyle: .hidden, isCollapsed: false, expandedWidth: SidebarSettings.defaultExpandedWidth),
            "a legacy bare-style file keeps its style and takes the defaults for the new fields"
        )
    }

    func test_partialStruct_defaultsMissingFields() {
        let partial = Data(#"{"collapseStyle":"icons"}"#.utf8)

        XCTAssertEqual(
            codec.decode(partial),
            SidebarSettings(collapseStyle: .icons, isCollapsed: false, expandedWidth: SidebarSettings.defaultExpandedWidth),
            "a file missing isCollapsed/expandedWidth defaults them rather than failing to decode"
        )
    }

    // MARK: Corrupt vs recoverable

    func test_unknownCollapseStyle_isNotDecodable() {
        let unknown = Data(#"{"collapseStyle":"sideways","isCollapsed":true,"expandedWidth":220}"#.utf8)

        XCTAssertNil(
            codec.decode(unknown),
            "an unknown collapse style is a corrupt file -- the caller must preserve, not reinterpret it"
        )
    }

    func test_outOfRangeWidth_stillDecodes_soLaunchIsNeverStranded() {
        let extreme = Data(#"{"collapseStyle":"icons","isCollapsed":false,"expandedWidth":100000}"#.utf8)

        XCTAssertEqual(
            codec.decode(extreme)?.expandedWidth, 100000,
            "an out-of-range width decodes as-is; clamping happens where the width is applied, not here"
        )
    }
}
