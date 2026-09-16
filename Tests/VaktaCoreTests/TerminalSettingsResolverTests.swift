//
//  TerminalSettingsResolverTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `TerminalFontSizeValidator` and
//  `TerminalThemeResolver`: normal, extreme, missing, and unknown inputs.

import GhosttyTheme
import XCTest
@testable import Vakta

final class TerminalFontSizeValidatorTests: XCTestCase {
    func test_effective_zero_isZero_ghosttyDefaultSentinel() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(0), 0)
    }

    func test_effective_normalSize_isUnchanged() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(13), 13)
    }

    func test_effective_boundaryValues_areKept() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(1), 1)
        XCTAssertEqual(TerminalFontSizeValidator.effective(200), 200)
    }

    func test_effective_negative_fallsBackToZero() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(-5), 0)
    }

    func test_effective_justBelowValidRange_fallsBackToZero() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(0.5), 0)
    }

    func test_effective_justAboveValidRange_fallsBackToZero() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(201), 0)
    }

    func test_effective_extremeFiniteValue_fallsBackToZero_doesNotTrapConvertingToInt() {
        // This exact value (well past Int64 range on conversion) is what
        // would have trapped `Int(_:)` before validation existed -- assert
        // the actual conversion on the validated result, not just that
        // `effective` itself returns something.
        let extreme = 1e300
        let validated = TerminalFontSizeValidator.effective(extreme)
        XCTAssertEqual(validated, 0)
        XCTAssertEqual(Int(validated), 0)
    }

    func test_effective_nan_fallsBackToZero() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(.nan), 0)
    }

    func test_effective_positiveInfinity_fallsBackToZero() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(.infinity), 0)
    }

    func test_effective_negativeInfinity_fallsBackToZero() {
        XCTAssertEqual(TerminalFontSizeValidator.effective(-.infinity), 0)
    }
}

final class TerminalThemeResolverTests: XCTestCase {
    func test_resolve_knownTheme_returnsThatDefinition() {
        let known = GhosttyThemeCatalog.allThemes.first!
        let resolved = TerminalThemeResolver.resolve(themeName: known.name)
        XCTAssertEqual(resolved, known)
    }

    func test_resolve_unknownTheme_fallsBackToTheDefaultThemeName() {
        let resolved = TerminalThemeResolver.resolve(themeName: "definitely-not-a-real-theme-name")
        let expected = GhosttyThemeCatalog.theme(named: TerminalSettings.defaultThemeName)
        XCTAssertEqual(resolved, expected)
    }

    func test_resolve_emptyThemeName_fallsBackToTheDefaultThemeName() {
        let resolved = TerminalThemeResolver.resolve(themeName: "")
        let expected = GhosttyThemeCatalog.theme(named: TerminalSettings.defaultThemeName)
        XCTAssertEqual(resolved, expected)
    }

    func test_defaultThemeName_isItselfAKnownCatalogTheme() {
        // Guards the "unreachable in practice" claim in `resolve`'s doc
        // comment -- if this ever stops being true, `ultimateFallback`
        // becomes reachable and every theme resolution silently degrades.
        XCTAssertNotNil(GhosttyThemeCatalog.theme(named: TerminalSettings.defaultThemeName))
    }

    func test_ultimateFallback_hasAllTheColorsApplyThemeColorsReadsIncludingAnAccent() {
        // If `defaultThemeName` ever did stop resolving, `ultimateFallback`
        // must still let terminal and chrome agree, including the accent
        // (`palette[4]`) -- a missing entry there would fall back to
        // `.controlAccentColor` for chrome while the terminal (built from
        // the same otherwise-complete definition) had no such fallback.
        XCTAssertNotNil(TerminalThemeResolver.ultimateFallback.palette[4])
    }
}
