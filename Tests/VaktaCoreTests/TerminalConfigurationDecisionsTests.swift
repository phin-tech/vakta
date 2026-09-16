//
//  TerminalConfigurationDecisionsTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `TerminalConfigurationDecisions`,
//  the pure extraction of `SessionStore.configureBuilder`'s decision of which
//  custom config pairs to emit. Covers the `keybind=clear` invariant
//  (docs/testing.md's `1148` row: "emitted configuration retains keybind
//  clearing") plus font family/size omission rules -- previously untestable
//  because the logic lived inline against a Ghostty `TerminalConfiguration.Builder`.

import XCTest
@testable import Vakta

final class TerminalConfigurationDecisionsTests: XCTestCase {
    func test_alwaysEmitsKeybindClearFirst() {
        let pairs = TerminalConfigurationDecisions.customPairs(for: TerminalSettings())
        XCTAssertEqual(pairs.first?.key, "keybind")
        XCTAssertEqual(pairs.first?.value, "clear")
    }

    func test_emptyFontFamily_omitsFontFamilyPair() {
        var settings = TerminalSettings()
        settings.fontFamily = ""
        let pairs = TerminalConfigurationDecisions.customPairs(for: settings)
        XCTAssertFalse(pairs.contains { $0.key == "font-family" })
    }

    func test_whitespaceOnlyFontFamily_omitsFontFamilyPair() {
        var settings = TerminalSettings()
        settings.fontFamily = "   "
        let pairs = TerminalConfigurationDecisions.customPairs(for: settings)
        XCTAssertFalse(pairs.contains { $0.key == "font-family" })
    }

    func test_fontFamilyWithSurroundingWhitespace_isTrimmedAndIncluded() {
        var settings = TerminalSettings()
        settings.fontFamily = "  SF Mono  "
        let pairs = TerminalConfigurationDecisions.customPairs(for: settings)
        XCTAssertEqual(pairs.first { $0.key == "font-family" }?.value, "SF Mono")
    }

    func test_zeroFontSize_omitsFontSizePair() {
        var settings = TerminalSettings()
        settings.fontSize = 0
        let pairs = TerminalConfigurationDecisions.customPairs(for: settings)
        XCTAssertFalse(pairs.contains { $0.key == "font-size" })
    }

    func test_invalidFontSize_negativeOrNonFinite_omitsFontSizePair() {
        for invalid: Double in [-5, .infinity, .nan] {
            var settings = TerminalSettings()
            settings.fontSize = invalid
            let pairs = TerminalConfigurationDecisions.customPairs(for: settings)
            XCTAssertFalse(pairs.contains { $0.key == "font-size" }, "fontSize=\(invalid)")
        }
    }

    func test_validFontSize_isIncludedFormattedWithG() {
        var settings = TerminalSettings()
        settings.fontSize = 13.5
        let pairs = TerminalConfigurationDecisions.customPairs(for: settings)
        XCTAssertEqual(pairs.first { $0.key == "font-size" }?.value, "13.5")
    }

    func test_extremeFontSize_isSanitizedThroughTheValidatorBeforeEmission() {
        var settings = TerminalSettings()
        settings.fontSize = 999_999
        let pairs = TerminalConfigurationDecisions.customPairs(for: settings)
        let effective = TerminalFontSizeValidator.effective(999_999)
        if effective > 0 {
            XCTAssertEqual(pairs.first { $0.key == "font-size" }?.value, String(format: "%g", effective))
        } else {
            XCTAssertFalse(pairs.contains { $0.key == "font-size" })
        }
    }
}
