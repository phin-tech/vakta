//
//  StatusBarViewModelTests.swift
//  VaktaIntegrationTests
//
//  The status bar's popover bookkeeping: Auto-hide holds the bar while any
//  popover (checks list, workspace list) is open, tracked per popover so a
//  late close of one can't release the hold while another is open.

import XCTest
@testable import Vakta

@MainActor
final class StatusBarViewModelTests: XCTestCase {
    func test_holdsWhileAnyPopoverIsOpen() {
        let model = StatusBarViewModel()
        XCTAssertFalse(model.isAnyPopoverOpen)

        model.setPopover(.checks, open: true)
        model.setPopover(.workspace, open: true)
        model.setPopover(.checks, open: false)
        XCTAssertTrue(model.isAnyPopoverOpen, "the workspace list is still open")

        model.setPopover(.workspace, open: false)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }

    func test_repeatedCloseIsHarmless() {
        let model = StatusBarViewModel()
        model.setPopover(.checks, open: false)
        model.setPopover(.checks, open: true)
        model.setPopover(.checks, open: true)
        model.setPopover(.checks, open: false)
        XCTAssertFalse(model.isAnyPopoverOpen)
    }
}
