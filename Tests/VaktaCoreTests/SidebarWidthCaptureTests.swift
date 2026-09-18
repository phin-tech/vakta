//
//  SidebarWidthCaptureTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the decision of whether a divider position the
//  user just dragged to should be recorded as the new *expanded* width.
//
//  This isolates a trap the codebase already hit once (see
//  `SidebarWidthPlanner`'s doc comment): the split view resizes both when the
//  user drags AND when `applySidebarWidth` calls `setPosition` to collapse.
//  Recording the collapsed rail width (56) or hidden width (0) as the
//  "expanded" width would corrupt the saved size. The capture must reject any
//  observation taken while collapsed, along with non-finite or sub-minimum
//  positions, and clamp anything above the maximum.

import XCTest
@testable import Vakta

final class SidebarWidthCaptureTests: XCTestCase {
    private let minimum: CGFloat = 120
    private let maximum: CGFloat = 480

    func test_expandedDragInRange_isAccepted() {
        XCTAssertEqual(
            SidebarWidthCapture.accepted(position: 260, isCollapsed: false, minimum: minimum, maximum: maximum),
            260
        )
    }

    func test_collapsedObservation_isRejected() {
        // The programmatic collapse to the icon rail must never be mistaken
        // for a user resizing the expanded sidebar.
        XCTAssertNil(
            SidebarWidthCapture.accepted(position: 56, isCollapsed: true, minimum: minimum, maximum: maximum)
        )
    }

    func test_positionBelowMinimum_isRejected() {
        // With no split-view delegate constraining the drag, the user can drag
        // the divider down to ~0; that is a collapse gesture, not a new width.
        XCTAssertNil(
            SidebarWidthCapture.accepted(position: 12, isCollapsed: false, minimum: minimum, maximum: maximum)
        )
    }

    func test_positionAboveMaximum_isClampedToMaximum() {
        XCTAssertEqual(
            SidebarWidthCapture.accepted(position: 900, isCollapsed: false, minimum: minimum, maximum: maximum),
            maximum
        )
    }

    func test_nonFinitePosition_isRejected() {
        XCTAssertNil(
            SidebarWidthCapture.accepted(position: .nan, isCollapsed: false, minimum: minimum, maximum: maximum)
        )
        XCTAssertNil(
            SidebarWidthCapture.accepted(position: .infinity, isCollapsed: false, minimum: minimum, maximum: maximum)
        )
    }
}
