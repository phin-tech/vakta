//
//  UnreadTrackingSettingsTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `UnreadTrackingSettings.trackedStatuses` -- the
//  set `UnreadAttentionPolicy.shouldMarkUnread` checks `to` against, derived
//  from the four independent toggles.

import XCTest
@testable import Vakta

final class UnreadTrackingSettingsTests: XCTestCase {
    func test_defaults_trackAttentionAndDoneOnly() {
        XCTAssertEqual(UnreadTrackingSettings().trackedStatuses, [.attention, .done])
    }

    func test_allEnabled_tracksAllFour() {
        let settings = UnreadTrackingSettings(trackAttention: true, trackDone: true, trackWorking: true, trackIdle: true)
        XCTAssertEqual(settings.trackedStatuses, [.attention, .done, .working, .idle])
    }

    func test_allDisabled_tracksNothing() {
        let settings = UnreadTrackingSettings(trackAttention: false, trackDone: false, trackWorking: false, trackIdle: false)
        XCTAssertEqual(settings.trackedStatuses, [])
    }

    func test_onlyWorkingEnabled_tracksOnlyWorking() {
        let settings = UnreadTrackingSettings(trackAttention: false, trackDone: false, trackWorking: true, trackIdle: false)
        XCTAssertEqual(settings.trackedStatuses, [.working])
    }
}
