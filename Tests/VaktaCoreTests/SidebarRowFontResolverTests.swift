//
//  SidebarRowFontResolverTests.swift
//  VaktaCoreTests
//
//  Functional-core, table-driven cases for `SidebarRowFontResolver`: the
//  fix for kata `me53` -- sidebar rows in terminal-match mode previously
//  ignored `terminalSettings.fontSize` entirely, always rendering at a
//  hardcoded 13pt regardless of the user's actual terminal font size.

import XCTest
@testable import Vakta

final class SidebarRowFontResolverTests: XCTestCase {
    // MARK: Explicit sidebar size (the Appearance preference)

    func test_explicitSidebarSize_winsOverTheTerminalSize() {
        XCTAssertEqual(SidebarRowFontResolver.fontSize(sidebarOverride: 11, matchingTerminal: 18), 11)
    }

    func test_explicitSidebarSize_winsEvenWhenTheTerminalIsAtItsDefault() {
        XCTAssertEqual(SidebarRowFontResolver.fontSize(sidebarOverride: 16, matchingTerminal: 0), 16)
    }

    func test_sidebarSizeSentinelZero_followsTheTerminalSize() {
        XCTAssertEqual(SidebarRowFontResolver.fontSize(sidebarOverride: 0, matchingTerminal: 18), 18)
        XCTAssertEqual(SidebarRowFontResolver.fontSize(sidebarOverride: 0, matchingTerminal: 0), 13)
    }

    func test_invalidSidebarSize_fromAHandEditedFile_followsTheTerminalSizeInstead() {
        for bad in [Double.nan, .infinity, -4, 1e300] {
            XCTAssertEqual(
                SidebarRowFontResolver.fontSize(sidebarOverride: bad, matchingTerminal: 18), 18, "\(bad)"
            )
        }
    }

    func test_hasExplicitSize_isTrueOnlyForAValidNonZeroSize() {
        // Drives whether the family-less terminal style drops Dynamic Type
        // for a fixed size: only when the user actually asked for one.
        XCTAssertTrue(SidebarRowFontResolver.hasExplicitSize(14))
        XCTAssertFalse(SidebarRowFontResolver.hasExplicitSize(0))
        XCTAssertFalse(SidebarRowFontResolver.hasExplicitSize(.nan))
        XCTAssertFalse(SidebarRowFontResolver.hasExplicitSize(1e300))
    }

    func test_normalTerminalFontSize_isUsedDirectly() {
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: 18), 18)
    }

    func test_terminalDefaultSentinelZero_fallsBackToTheConstant() {
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: 0), 13)
    }

    func test_customFallback_isHonoredWhenTerminalIsAtDefault() {
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: 0, fallback: 15), 15)
    }

    func test_boundaryStepperValues_areUsedDirectly() {
        // The Stepper in TerminalPreferencesView only ever produces 0 or
        // 9...32; both ends of that live range pass through unchanged.
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: 9), 9)
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: 32), 32)
    }

    func test_outOfRangeValue_fromAHandEditedFile_fallsBackRatherThanRenderingAtIt() {
        // `TerminalSettingsStore` only validates `fontSize` at load; a value
        // set through any other path (not the bounded Stepper) is not
        // re-validated on every subsequent read, so this resolver must not
        // trust it's already in range.
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: 1e300), 13)
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: -5), 13)
    }

    func test_nonFiniteValue_fallsBackRatherThanCrashingSwiftUILayout() {
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: .nan), 13)
        XCTAssertEqual(SidebarRowFontResolver.fontSize(matchingTerminal: .infinity), 13)
    }
}
