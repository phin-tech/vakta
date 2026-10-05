//
//  RightSidebarRailTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the right sidebar's collapsed icon rail: one
//  icon per available Panel View, in order, decorated with that Extension's
//  own Status Item (the same push-based data `status/set` already delivers)
//  as a short badge -- a collapsed Extension can show live state without a
//  second protocol message. Not yet implemented: `RightSidebarRail` and
//  `RightSidebarRailIcon` don't exist yet (RED).
//

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class RightSidebarRailTests: XCTestCase {
    private let kata = PanelViewOption(ref: PanelViewRef(extensionID: "kata", viewID: "issues"), title: "Issues", symbol: "checklist")
    private let github = PanelViewOption(ref: PanelViewRef(extensionID: "github", viewID: "prs"), title: "Pull Requests", symbol: "arrow.triangle.pull")

    private func statusItem(extensionID: String, text: String, tint: StatusSegment.Tint = .neutral) -> StatusBarExtensionItem {
        StatusBarExtensionItem(
            extensionID: extensionID,
            placement: .leading,
            segments: [StatusBarSegment(
                index: 0, text: text, symbol: nil, tint: tint, help: nil, action: nil, url: nil, popover: nil,
                attention: false, placement: .leading
            )]
        )
    }

    func test_oneIconPerAvailableOption_inOrder_withNoBadgeWithoutAStatusItem() {
        let icons = RightSidebarRail.icons(options: [kata, github], statusItems: [], activeMode: .files)
        XCTAssertEqual(icons.map(\.ref), [kata.ref, github.ref])
        XCTAssertEqual(icons.map(\.symbol), [kata.symbol, github.symbol])
        XCTAssertTrue(icons.allSatisfy { $0.badgeText == nil })
    }

    func test_matchingStatusItem_suppliesTheBadgeText_truncatedToFourCharacters() {
        let icons = RightSidebarRail.icons(options: [kata], statusItems: [statusItem(extensionID: "kata", text: "12 ready")], activeMode: .files)
        XCTAssertEqual(icons.first?.badgeText, "12 …")
    }

    func test_statusItemForADifferentExtension_isIgnored() {
        let icons = RightSidebarRail.icons(options: [kata], statusItems: [statusItem(extensionID: "github", text: "3")], activeMode: .files)
        XCTAssertNil(icons.first?.badgeText)
    }

    func test_tintFollowsTheMatchingStatusItemsFirstSegment() {
        let icons = RightSidebarRail.icons(options: [kata], statusItems: [statusItem(extensionID: "kata", text: "!", tint: .failure)], activeMode: .files)
        XCTAssertEqual(icons.first?.tint, .failure)
    }

    func test_activeModeMarksItsOwnIconActive_andNoOtherIcon() {
        let icons = RightSidebarRail.icons(options: [kata, github], statusItems: [], activeMode: .extensionView(kata.ref))
        XCTAssertEqual(icons.map(\.isActive), [true, false])
    }

    func test_filesOrChangesMode_leavesEveryIconInactive() {
        for mode in [FileSidebarMode.files, .changes] {
            let icons = RightSidebarRail.icons(options: [kata], statusItems: [], activeMode: mode)
            XCTAssertEqual(icons.first?.isActive, false, "\(mode)")
        }
    }
}
