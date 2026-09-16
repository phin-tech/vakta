//
//  HerdrPreferencesTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrPreferences`: the toggleable "show
//  workspaces under a herdr session" preference, off by default. Off by
//  default because the sidebar disclosure this gates runs a `herdr
//  workspace list` query (fetch-on-expand, not a continuous poll) the first
//  time a herdr session row is expanded -- opt-in, not a surprise on upgrade.

import XCTest
@testable import Vakta

final class HerdrPreferencesTests: XCTestCase {
    func test_default_showWorkspacesIsFalse() {
        XCTAssertFalse(HerdrPreferences().showWorkspaces)
    }

    func test_decode_missingField_defaultsToFalse() throws {
        // Migration case: a `herdr.json` written before this field existed.
        // Swift's synthesized `Decodable` does NOT fall back to a property's
        // default when the key is absent -- it throws `keyNotFound`. This
        // needs an explicit `init(from:)` using `decodeIfPresent(_:forKey:) ??
        // false`, same shape as any other settings struct that has grown a
        // field after its first release.
        let decoded = try JSONDecoder().decode(HerdrPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.showWorkspaces)
    }

    func test_decode_explicitTrue_isHonored() throws {
        let decoded = try JSONDecoder().decode(HerdrPreferences.self, from: Data(#"{"showWorkspaces":true}"#.utf8))
        XCTAssertTrue(decoded.showWorkspaces)
    }

    func test_roundTrip_preservesValue() throws {
        let original = HerdrPreferences(showWorkspaces: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HerdrPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
