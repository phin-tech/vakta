//
//  ExtensionRegistryCodecTests.swift
//  VaktaCoreTests
//
//  The `extensions.json` envelope: round trip, omitted fields, and a future
//  version left undecodable so the store preserves it.

import XCTest
@testable import Vakta

final class ExtensionRegistryCodecTests: XCTestCase {
    private let codec = ExtensionRegistryFileCodec()

    func test_roundTrip() throws {
        let registry = ExtensionRegistry(records: [
            LinkedExtensionRecord(
                directory: "/Users/sam/src/vakta/extensions/kata", enabled: true, developerMode: true,
                approved: TrustFingerprint(manifestSHA256: "aa", executableSHA256: nil)
            ),
            LinkedExtensionRecord(directory: "/opt/ext", enabled: false, developerMode: false, approved: nil),
        ])
        let data = try XCTUnwrap(codec.encode(registry))
        XCTAssertEqual(codec.decode(data), registry)
    }

    func test_omittedFlags_defaultToEnabledAndNotDeveloperMode() {
        let json = #"{"version": 1, "records": [{"directory": "/opt/ext"}]}"#
        XCTAssertEqual(
            codec.decode(Data(json.utf8)),
            ExtensionRegistry(records: [
                LinkedExtensionRecord(directory: "/opt/ext", enabled: true, developerMode: false, approved: nil),
            ])
        )
    }

    func test_futureVersionOrMalformed_isNotDecodable() {
        for json in [#"{"version": 2, "records": []}"#, #"{"records": []}"#, "[]", "not json"] {
            XCTAssertNil(codec.decode(Data(json.utf8)), json)
        }
    }
}

final class ExtensionNotificationPolicyTests: XCTestCase {
    func test_omittedNotificationsFlag_defaultsOn() {
        let registry = ExtensionRegistryFileCodec().decode(Data(#"{"version": 1, "records": [{"directory": "/opt/ext"}]}"#.utf8))
        XCTAssertEqual(registry?.records.first?.notifications, true)
    }

    func test_shouldDeliver() {
        func deliver(_ allows: Bool, _ allowed: Bool, aboutSelected: Bool, active: Bool) -> Bool {
            ExtensionNotificationPolicy.shouldDeliver(extensionAllows: allows, notificationsAllowed: allowed, isAboutSelectedSession: aboutSelected, appActive: active)
        }
        XCTAssertTrue(deliver(true, true, aboutSelected: false, active: true))
        XCTAssertTrue(deliver(true, true, aboutSelected: true, active: false), "you're not looking: Vakta is in the background")
        XCTAssertFalse(deliver(true, true, aboutSelected: true, active: true), "you're already looking at that Session")
        XCTAssertFalse(deliver(false, true, aboutSelected: false, active: true), "this Extension's notifications are off")
        XCTAssertFalse(deliver(true, false, aboutSelected: false, active: true), "notifications are off in Vakta")
    }
}
