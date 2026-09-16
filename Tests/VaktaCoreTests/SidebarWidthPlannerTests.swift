//
//  SidebarWidthPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `SidebarWidthPlanner.width`
//  covering every collapsed/style combination.

import XCTest
@testable import Vakta

final class SidebarWidthPlannerTests: XCTestCase {
    private let collapsedWidth: CGFloat = 56
    private let expandedWidth: CGFloat = 220

    func test_collapsed_iconsStyle_isTheCollapsedWidth() {
        let width = SidebarWidthPlanner.width(
            collapsed: true,
            style: .icons,
            collapsedWidth: collapsedWidth,
            expandedWidth: expandedWidth
        )
        XCTAssertEqual(width, collapsedWidth)
    }

    func test_collapsed_hiddenStyle_isZero() {
        let width = SidebarWidthPlanner.width(
            collapsed: true,
            style: .hidden,
            collapsedWidth: collapsedWidth,
            expandedWidth: expandedWidth
        )
        XCTAssertEqual(width, 0)
    }

    func test_collapsed_switchingIconsToHidden_immediatelyGoesToZero() {
        // AC: "While collapsed, switching Icons to Hidden immediately sets
        // zero width" -- both computed against the same `collapsed: true`,
        // only `style` differs, as the emitted value would arrive.
        let before = SidebarWidthPlanner.width(collapsed: true, style: .icons, collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        let after = SidebarWidthPlanner.width(collapsed: true, style: .hidden, collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        XCTAssertEqual(before, collapsedWidth)
        XCTAssertEqual(after, 0)
    }

    func test_collapsed_switchingHiddenToIcons_immediatelyRestoresTheRail() {
        let before = SidebarWidthPlanner.width(collapsed: true, style: .hidden, collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        let after = SidebarWidthPlanner.width(collapsed: true, style: .icons, collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        XCTAssertEqual(before, 0)
        XCTAssertEqual(after, collapsedWidth)
    }

    func test_expanded_iconsStyle_isTheExpandedWidth() {
        let width = SidebarWidthPlanner.width(
            collapsed: false,
            style: .icons,
            collapsedWidth: collapsedWidth,
            expandedWidth: expandedWidth
        )
        XCTAssertEqual(width, expandedWidth)
    }

    func test_expanded_hiddenStyle_stillTheExpandedWidth() {
        // AC: "While expanded, changing collapse style leaves the expanded
        // width until the next collapse" -- style is irrelevant while expanded.
        let width = SidebarWidthPlanner.width(
            collapsed: false,
            style: .hidden,
            collapsedWidth: collapsedWidth,
            expandedWidth: expandedWidth
        )
        XCTAssertEqual(width, expandedWidth)
    }

    func test_expanded_changingStyleWhileExpanded_doesNotChangeWidth() {
        let withIcons = SidebarWidthPlanner.width(collapsed: false, style: .icons, collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        let withHidden = SidebarWidthPlanner.width(collapsed: false, style: .hidden, collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        XCTAssertEqual(withIcons, withHidden)
        XCTAssertEqual(withIcons, expandedWidth)
    }
}
