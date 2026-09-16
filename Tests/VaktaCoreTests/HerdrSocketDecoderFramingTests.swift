//
//  HerdrSocketDecoderFramingTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrSocketDecoder.extractLines`, which splits
//  accumulated socket bytes into complete newline-terminated lines plus
//  whatever incomplete tail remains buffered -- a `recv` can split one frame
//  across two reads, or deliver several frames in one (see
//  docs/herdr-events-plan.md's Darwin `sun_path`/framing risk note). Kept
//  pure and separate from `HerdrEventStreamClient`'s actual socket I/O.

import XCTest
@testable import Vakta

final class HerdrSocketDecoderFramingTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    func test_oneCompleteLine_extractsItWithNoRemainder() {
        let (lines, remainder) = HerdrSocketDecoder.extractLines(from: data("{\"a\":1}\n"))

        XCTAssertEqual(lines, ["{\"a\":1}"])
        XCTAssertTrue(remainder.isEmpty)
    }

    func test_twoLinesInOneBuffer_extractsBoth() {
        let (lines, remainder) = HerdrSocketDecoder.extractLines(from: data("{\"a\":1}\n{\"b\":2}\n"))

        XCTAssertEqual(lines, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertTrue(remainder.isEmpty)
    }

    func test_lineSplitAcrossTwoReads_secondCallCompletesIt() {
        let (firstLines, remainder) = HerdrSocketDecoder.extractLines(from: data("{\"a\":"))
        XCTAssertEqual(firstLines, [])

        var combined = remainder
        combined.append(data("1}\n"))
        let (secondLines, secondRemainder) = HerdrSocketDecoder.extractLines(from: combined)

        XCTAssertEqual(secondLines, ["{\"a\":1}"])
        XCTAssertTrue(secondRemainder.isEmpty)
    }

    func test_emptyBuffer_extractsNothing() {
        let (lines, remainder) = HerdrSocketDecoder.extractLines(from: Data())

        XCTAssertEqual(lines, [])
        XCTAssertTrue(remainder.isEmpty)
    }

    func test_bufferWithNoNewlineYet_isHeldEntirelyAsRemainder() {
        let (lines, remainder) = HerdrSocketDecoder.extractLines(from: data("{\"incomplete"))

        XCTAssertEqual(lines, [])
        XCTAssertEqual(remainder, data("{\"incomplete"))
    }

    func test_completeLinePlusPartialNextLine_extractsCompleteAndBuffersRest() {
        let (lines, remainder) = HerdrSocketDecoder.extractLines(from: data("{\"a\":1}\n{\"b\":"))

        XCTAssertEqual(lines, ["{\"a\":1}"])
        XCTAssertEqual(remainder, data("{\"b\":"))
    }
}
