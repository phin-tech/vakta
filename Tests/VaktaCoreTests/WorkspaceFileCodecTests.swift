//
//  WorkspaceFileCodecTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `WorkspaceFileCodec`: decode/migration from raw
//  bytes to `WorkspacePayload`, with no file I/O.

import XCTest
@testable import Vakta

final class WorkspaceFileCodecTests: XCTestCase {
    private let codec = WorkspaceFileCodec()

    private func record(_ name: String) -> SessionRecord {
        SessionRecord(profileID: UUID(), sessionName: name, customName: nil, workingDirectory: nil)
    }

    func test_decode_currentEnvelope_succeeds() throws {
        let payload = WorkspacePayload(records: [record("one")], selectedSessionName: "one")
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(codec.decode(data), payload)
    }

    func test_decode_legacyBareArray_migratesWithNoSelection() throws {
        let legacy = [record("one"), record("two")]
        let data = try JSONEncoder().encode(legacy)
        XCTAssertEqual(codec.decode(data), WorkspacePayload(records: legacy, selectedSessionName: nil))
    }

    func test_decode_malformedJSON_returnsNil() {
        XCTAssertNil(codec.decode(Data("not json {".utf8)))
    }

    func test_encode_thenDecode_roundTrips() throws {
        let payload = WorkspacePayload(records: [record("one")], selectedSessionName: "one")
        let data = try XCTUnwrap(codec.encode(payload))
        XCTAssertEqual(codec.decode(data), payload)
    }
}
