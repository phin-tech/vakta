//
//  DirectoryListingTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the file sidebar's ordering/visibility rules:
//  how one directory's raw children are sorted and filtered for display. No
//  filesystem access -- see `DirectoryReaderShellTests` for the real read.
//

import XCTest
@testable import Vakta

final class DirectoryListingTests: XCTestCase {
    private func e(_ name: String, dir: Bool = false) -> FileEntry {
        FileEntry(name: name, isDirectory: dir)
    }

    func test_directoriesSortBeforeFiles() {
        let sorted = DirectoryListing.sorted([e("readme.md"), e("src", dir: true)], showHidden: false)
        XCTAssertEqual(sorted, [e("src", dir: true), e("readme.md")])
    }

    func test_caseInsensitiveAlphabeticalWithinEachGroup() {
        let sorted = DirectoryListing.sorted(
            [e("Zebra"), e("apple"), e("Banana"), e("bin", dir: true), e("App", dir: true)],
            showHidden: false
        )
        XCTAssertEqual(sorted.map(\.name), ["App", "bin", "apple", "Banana", "Zebra"])
    }

    func test_dotfilesHiddenByDefault() {
        let sorted = DirectoryListing.sorted([e(".git", dir: true), e(".env"), e("main.swift")], showHidden: false)
        XCTAssertEqual(sorted.map(\.name), ["main.swift"])
    }

    func test_dotfilesShownWhenRequested() {
        let sorted = DirectoryListing.sorted([e(".git", dir: true), e("main.swift"), e(".env")], showHidden: true)
        XCTAssertEqual(sorted.map(\.name), [".git", ".env", "main.swift"])
    }

    func test_emptyInput_isEmpty() {
        XCTAssertEqual(DirectoryListing.sorted([], showHidden: true), [])
    }
}
