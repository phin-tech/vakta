//
//  FileRowClickPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for what a click on a file sidebar row does. Rows
//  act on the first click immediately (no waiting to see whether a second
//  click follows), so a double-click is the first click's action plus
//  whatever the second adds.
//

import XCTest
@testable import Vakta

final class FileRowClickPlannerTests: XCTestCase {
    func test_singleClick_onDirectory_togglesImmediately() {
        XCTAssertEqual(FileRowClickPlanner.action(clickCount: 1, isDirectory: true, canOpen: true), .toggleExpansion)
    }

    func test_doubleClick_onDirectory_addsNothing_soItDoesNotToggleBack() {
        // The first click already toggled; toggling again would undo it.
        XCTAssertEqual(FileRowClickPlanner.action(clickCount: 2, isDirectory: true, canOpen: true), .select)
    }

    func test_singleClick_onFile_onlySelects() {
        XCTAssertEqual(FileRowClickPlanner.action(clickCount: 1, isDirectory: false, canOpen: true), .select)
    }

    func test_doubleClick_onFile_opens() {
        XCTAssertEqual(FileRowClickPlanner.action(clickCount: 2, isDirectory: false, canOpen: true), .open)
    }

    func test_doubleClick_onFileThatCannotBeOpened_onlySelects() {
        XCTAssertEqual(FileRowClickPlanner.action(clickCount: 2, isDirectory: false, canOpen: false), .select)
    }

    func test_tripleClick_isNotASecondOpen() {
        XCTAssertEqual(FileRowClickPlanner.action(clickCount: 3, isDirectory: false, canOpen: true), .select)
    }
}
