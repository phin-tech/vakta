//
//  OnboardingStateCodecTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `OnboardingState` decoding: an empty or older
//  file decodes with no last-seen version, and unknown keys are ignored.
//

import XCTest
@testable import Vakta

final class OnboardingStateCodecTests: XCTestCase {
    private func decode(_ json: String) throws -> OnboardingState {
        try JSONDecoder().decode(OnboardingState.self, from: Data(json.utf8))
    }

    func test_emptyObject_hasNoLastSeenVersion() throws {
        XCTAssertEqual(try decode("{}"), OnboardingState(lastSeenVersion: nil))
    }

    func test_unknownKeys_areIgnored() throws {
        XCTAssertEqual(try decode(#"{"lastSeenVersion": "1.2.0", "future": true}"#), OnboardingState(lastSeenVersion: "1.2.0"))
    }

    func test_roundTrips() throws {
        let original = OnboardingState(lastSeenVersion: "1.2.0-beta.1")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(OnboardingState.self, from: data), original)
    }
}
