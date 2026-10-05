//
//  LineSplitterTests.swift
//  VaktaCoreTests
//
//  Splitting an Extension's stdout into protocol lines across arbitrary
//  chunk boundaries, with oversize lines dropped instead of buffered.

import XCTest
@testable import Vakta

final class LineSplitterTests: XCTestCase {
    func test_linesAcrossChunkBoundaries() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.append(Data("{\"a\":".utf8)).lines, [])
        XCTAssertEqual(splitter.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8)).lines, [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(splitter.append(Data(":3}\n".utf8)).lines, [#"{"c":3}"#])
    }

    func test_multibyteCharacterSplitAcrossChunks_isIntact() {
        var splitter = LineSplitter()
        let bytes = Array("ü\n".utf8)
        XCTAssertEqual(splitter.append(Data(bytes[..<1])).lines, [])
        XCTAssertEqual(splitter.append(Data(bytes[1...])).lines, ["ü"])
    }

    func test_oversizeLine_isDropped_andTheNextLineSurvives() {
        var splitter = LineSplitter(maxLineBytes: 4)
        let first = splitter.append(Data("123456".utf8))
        XCTAssertEqual(first.lines, [])
        XCTAssertEqual(first.dropped, 1)
        XCTAssertEqual(splitter.append(Data("789\nok\n".utf8)).lines, ["ok"])
    }
}
