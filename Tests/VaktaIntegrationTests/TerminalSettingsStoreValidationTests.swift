//
//  TerminalSettingsStoreValidationTests.swift
//  VaktaIntegrationTests
//
//  Shell case proving an extreme/malformed persisted fontSize is actually
//  sanitized when TerminalSettingsStore loads it -- not just that
//  TerminalFontSizeValidator's pure math looks right (see
//  TerminalSettingsResolverTests). Writes a real terminal.json with an
//  out-of-range value directly, simulating a hand-edited or corrupt file,
//  and loads it through the real store.

import XCTest
@testable import Vakta

@MainActor
final class TerminalSettingsStoreValidationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalSettingsStoreValidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func writeRawTerminalJSON(_ json: String) throws {
        let fileURL = TerminalSettingsPersistence.store(root: tempDirectory).fileURL
        try Data(json.utf8).write(to: fileURL)
    }

    func test_extremeFontSize_isSanitizedOnLoad() throws {
        try writeRawTerminalJSON(#"{"fontFamily":"","fontSize":1e300,"themeName":"Dracula"}"#)

        let store = TerminalSettingsStore(root: tempDirectory)

        XCTAssertEqual(store.fontSize, 0, "an out-of-range decoded fontSize must never reach the live store")
    }

    func test_negativeFontSize_isSanitizedOnLoad() throws {
        try writeRawTerminalJSON(#"{"fontFamily":"","fontSize":-42,"themeName":"Dracula"}"#)
        let store = TerminalSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.fontSize, 0)
    }

    func test_normalFontSize_isPreservedOnLoad() throws {
        try writeRawTerminalJSON(#"{"fontFamily":"SF Mono","fontSize":14,"themeName":"Dracula"}"#)
        let store = TerminalSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.fontSize, 14)
        XCTAssertEqual(store.fontFamily, "SF Mono")
    }
}
