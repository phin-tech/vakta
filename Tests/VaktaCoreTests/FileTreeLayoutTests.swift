//
//  FileTreeLayoutTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for flattening the Files tree into the rows the
//  sidebar draws: depth-first over loaded directories, only into expanded
//  ones. Pure values -- see `FileTreeModelTests` for loading.
//

import XCTest
@testable import Vakta

final class FileTreeLayoutTests: XCTestCase {
    private func e(_ name: String, dir: Bool = false) -> FileEntry {
        FileEntry(name: name, isDirectory: dir)
    }

    func test_unloadedRoot_hasNoRows() {
        XCTAssertEqual(FileTreeLayout.visibleRows(root: "/r", children: [:], expanded: []), [])
    }

    func test_rootChildren_areDepthZero_inTheGivenOrder() {
        let rows = FileTreeLayout.visibleRows(root: "/r", children: ["/r": [e("src", dir: true), e("a.txt")]], expanded: [])
        XCTAssertEqual(rows, [
            FileTreeRow(path: "/r/src", name: "src", isDirectory: true, depth: 0, isExpanded: false),
            FileTreeRow(path: "/r/a.txt", name: "a.txt", isDirectory: false, depth: 0, isExpanded: false),
        ])
    }

    func test_expandedLoadedDirectory_listsItsChildrenBeneathIt() {
        let rows = FileTreeLayout.visibleRows(
            root: "/r",
            children: [
                "/r": [e("src", dir: true), e("z.txt")],
                "/r/src": [e("lib", dir: true), e("main.swift")],
                "/r/src/lib": [e("x.swift")],
            ],
            expanded: ["/r/src", "/r/src/lib"]
        )
        XCTAssertEqual(rows.map(\.path), ["/r/src", "/r/src/lib", "/r/src/lib/x.swift", "/r/src/main.swift", "/r/z.txt"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(rows.map(\.isExpanded), [true, true, false, false, false])
    }

    func test_collapsedDirectory_hidesItsLoadedChildren() {
        let rows = FileTreeLayout.visibleRows(
            root: "/r",
            children: ["/r": [e("src", dir: true)], "/r/src": [e("main.swift")]],
            expanded: []
        )
        XCTAssertEqual(rows.map(\.path), ["/r/src"])
    }

    func test_expandedButNotYetLoaded_showsTheRowExpanded_withNoChildrenYet() {
        let rows = FileTreeLayout.visibleRows(root: "/r", children: ["/r": [e("src", dir: true)]], expanded: ["/r/src"])
        XCTAssertEqual(rows, [FileTreeRow(path: "/r/src", name: "src", isDirectory: true, depth: 0, isExpanded: true)])
    }

    func test_rootWithTrailingSlash_doesNotDoubleTheSeparator() {
        let rows = FileTreeLayout.visibleRows(root: "/", children: ["/": [e("tmp", dir: true)]], expanded: [])
        XCTAssertEqual(rows.map(\.path), ["/tmp"])
    }
}
