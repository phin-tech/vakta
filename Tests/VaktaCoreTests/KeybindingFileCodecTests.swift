//
//  KeybindingFileCodecTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `KeybindingFileCodec`: decode/migration
//  decisions from raw bytes to `StoredKeybindingsPayload`, with no file I/O.
//  Part of kata issue k916 (shared persistence boundary).

import XCTest
@testable import Vakta

final class KeybindingFileCodecTests: XCTestCase {
    private let codec = KeybindingFileCodec()

    private func binding(_ key: UInt16 = 1) -> Keybinding {
        Keybinding(modifierMask: .command, keyCode: key, action: .toggleSidebar)
    }

    func test_decode_currentVersionEnvelope_succeeds() throws {
        let payload = StoredKeybindingsPayload(version: KeybindingFileCodec.currentVersion, bindings: [binding()])
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(codec.decode(data), payload)
    }

    func test_decode_legacyBareArray_migratesToVersionOne() throws {
        // A file written before the versioned envelope existed: a bare
        // `[Keybinding]` array, treated as schema version 1.
        let bindings = [binding(1), binding(2)]
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(codec.decode(data), StoredKeybindingsPayload(version: 1, bindings: bindings))
    }

    func test_decode_olderKnownVersion_isLoadedWithItsVersionPreserved() throws {
        // v2 (predating v3's ⌘Q quit addition) is a real on-disk state for
        // any user who ran a v2 build -- `KeybindingMatcher.init` migrates
        // forward from whatever version `load()` reports, so the codec must
        // not treat "not current" as "not decodable."
        let data = Data(#"{"version":2,"bindings":[]}"#.utf8)
        XCTAssertEqual(codec.decode(data), StoredKeybindingsPayload(version: 2, bindings: []))
    }

    func test_decode_malformedJSON_returnsNil() {
        let data = Data("not json at all {".utf8)
        XCTAssertNil(codec.decode(data))
    }

    func test_decode_versionNewerThanCurrent_returnsNilRatherThanReinterpreting() throws {
        let data = Data(
            #"{"version":\#(KeybindingFileCodec.currentVersion + 1),"bindings":[]}"#.utf8
        )
        XCTAssertNil(
            codec.decode(data),
            "a future schema version must not be silently downgraded/reinterpreted as current"
        )
    }

    func test_encode_thenDecode_roundTrips() throws {
        let payload = StoredKeybindingsPayload(version: KeybindingFileCodec.currentVersion, bindings: [binding(9)])
        let data = try XCTUnwrap(codec.encode(payload))
        XCTAssertEqual(codec.decode(data), payload)
    }

    // ⌘, open-preferences: v7 adds the default ⌘, binding on top of v6's
    // font-size zoom (see `KeybindingStartupPlannerTests`). Supersedes the
    // transient "isSix" assertion -- `currentVersion` only ever has one
    // "current" value at a time.
    func test_currentVersion_isSeven_forOpenPreferencesDefault() {
        XCTAssertEqual(
            KeybindingFileCodec.currentVersion,
            7,
            "adding the default ⌘, open-preferences binding is a schema migration and must bump currentVersion"
        )
    }
}
