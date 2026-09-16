//
//  PaletteAppendPlannerTests.swift
//  VaktaCoreTests
//
//  RED, slice 1 of the ⌘K command palette generalization. Pure
//  stale-completion guard for appending async-fetched items (herdr
//  workspaces) into an already-open palette.

import XCTest
@testable import Vakta

final class PaletteAppendPlannerTests: XCTestCase {
    func test_shouldApply_sameGeneration_isTrue() {
        XCTAssertTrue(PaletteAppendPlanner.shouldApply(fetchGeneration: 1, currentGeneration: 1))
    }

    func test_shouldApply_staleGeneration_isFalse() {
        // The palette was reset (closed/reopened) after the fetch started.
        XCTAssertFalse(PaletteAppendPlanner.shouldApply(fetchGeneration: 1, currentGeneration: 2))
    }

    func test_shouldApply_fetchFromFutureGeneration_isFalse() {
        // Defensive: a fetch tagged with a generation newer than current
        // should never happen, but must not be treated as "apply."
        XCTAssertFalse(PaletteAppendPlanner.shouldApply(fetchGeneration: 3, currentGeneration: 2))
    }
}
