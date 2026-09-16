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
