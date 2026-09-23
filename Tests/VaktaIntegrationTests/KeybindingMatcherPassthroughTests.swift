//
//  KeybindingMatcherPassthroughTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `KeybindingMatcher.detectPassthroughToggle` (driven only
//  through `handle`, its real entry point) and the small `clearBinding`/
//  `resetToDefaults` mutators -- none of these had any coverage before this
//  file (0% on KeybindingMatcher.swift's passthrough branches per
//  `docs/testing.md`'s `560r`/Passthrough row). Uses real synthesized
//  `.flagsChanged` `NSEvent`s with supplied timestamps, matching the
//  existing `KeybindingMatcherRoutingTests` style -- no mocks.

import AppKit
import XCTest
@testable import Vakta

@MainActor
final class KeybindingMatcherPassthroughTests: XCTestCase {
    /// Real `NSEvent.timestamp`s are seconds since system boot -- always far
    /// from zero. `lastTapTime` starts at `0`, so a naive test timestamp near
    /// zero can alias with that initial value and look like a completed
    /// double-tap on the very first release. All timestamps below are offset
    /// from this base to avoid that false positive.
    private let base: TimeInterval = 100_000

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybindingMatcherPassthroughTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func flagsChangedEvent(modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        )!
    }

    private func keyDownEvent(modifiers: NSEvent.ModifierFlags = [], timestamp: TimeInterval = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
    }

    /// Presses and releases `modifier` alone at `timestamp` -- a clean tap.
    private func tap(_ matcher: KeybindingMatcher, modifier: NSEvent.ModifierFlags, at timestamp: TimeInterval) {
        _ = matcher.handle(flagsChangedEvent(modifiers: modifier, timestamp: timestamp)) { _ in }
        _ = matcher.handle(flagsChangedEvent(modifiers: [], timestamp: timestamp)) { _ in }
    }

    func test_passthrough_startsOff() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        XCTAssertFalse(matcher.passthrough)
    }

    func test_doubleTapWithinWindow_shiftToggle_entersPassthrough() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .shift

        tap(matcher, modifier: .shift, at: base)
        tap(matcher, modifier: .shift, at: base + 0.2)

        XCTAssertTrue(matcher.passthrough)
    }

    func test_doubleTapWithinWindow_tappedAgain_exitsPassthrough() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .shift
        tap(matcher, modifier: .shift, at: base)
        tap(matcher, modifier: .shift, at: base + 0.2)
        XCTAssertTrue(matcher.passthrough)

        tap(matcher, modifier: .shift, at: base + 1.0)
        tap(matcher, modifier: .shift, at: base + 1.2)

        XCTAssertFalse(matcher.passthrough)
    }

    func test_tapsBeyondDoubleTapWindow_doNotToggle() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .shift

        tap(matcher, modifier: .shift, at: base)
        tap(matcher, modifier: .shift, at: base + 5.0)

        XCTAssertFalse(matcher.passthrough)
    }

    func test_keyPressDuringHold_interruptsTheDoubleTap() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .shift

        _ = matcher.handle(flagsChangedEvent(modifiers: .shift, timestamp: base)) { _ in }
        _ = matcher.handle(keyDownEvent(modifiers: .shift, timestamp: base + 0.05)) { _ in }
        _ = matcher.handle(flagsChangedEvent(modifiers: [], timestamp: base + 0.1)) { _ in }
        tap(matcher, modifier: .shift, at: base + 0.2)

        XCTAssertFalse(matcher.passthrough)
    }

    func test_unrelatedModifierDuringHold_interruptsTheDoubleTap() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .shift

        _ = matcher.handle(flagsChangedEvent(modifiers: .shift, timestamp: base)) { _ in }
        _ = matcher.handle(flagsChangedEvent(modifiers: [.shift, .command], timestamp: base + 0.05)) { _ in }
        _ = matcher.handle(flagsChangedEvent(modifiers: [], timestamp: base + 0.1)) { _ in }
        tap(matcher, modifier: .shift, at: base + 0.2)

        XCTAssertFalse(matcher.passthrough)
    }

    func test_toggleOff_disablesDetectionEntirely() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .off

        tap(matcher, modifier: .shift, at: base)
        tap(matcher, modifier: .shift, at: base + 0.2)

        XCTAssertFalse(matcher.passthrough)
    }

    func test_switchingToggleModifier_resetsAnyPendingTapGesture() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .shift
        // First half of a shift tap is pending (pressed, not yet released).
        _ = matcher.handle(flagsChangedEvent(modifiers: .shift, timestamp: base)) { _ in }

        matcher.passthroughToggle = .command
        tap(matcher, modifier: .command, at: base + 0.05)
        tap(matcher, modifier: .command, at: base + 0.2)

        XCTAssertTrue(matcher.passthrough)
    }

    func test_whilePassthroughIsOn_normalKeysFallThroughUnfired() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.passthroughToggle = .shift
        matcher.setBinding(.command, keyCode: 7, for: .toggleSidebar)
        tap(matcher, modifier: .shift, at: base)
        tap(matcher, modifier: .shift, at: base + 0.2)
        XCTAssertTrue(matcher.passthrough)

        var fired: AppCommand?
        let result = matcher.handle(keyDownEvent(modifiers: .command, timestamp: base + 1)) { fired = $0 }

        XCTAssertNotNil(result)
        XCTAssertNil(fired)
    }

    func test_clearBinding_removesOnlyTheMatchingAction() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.setBinding(.command, keyCode: 7, for: .toggleSidebar)
        matcher.setBinding(.command, keyCode: 8, for: .openPreferences)

        matcher.clearBinding(for: .toggleSidebar)

        XCTAssertNil(matcher.binding(for: .toggleSidebar))
        XCTAssertNotNil(matcher.binding(for: .openPreferences))
    }

    func test_clearBinding_unboundAction_isANoOp() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        let before = matcher.bindings

        matcher.clearBinding(for: .toggleSidebar)

        XCTAssertEqual(matcher.bindings, before)
    }

    func test_resetToDefaults_restoresShippedDefaults() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.setBinding(.command, keyCode: 99, for: .toggleSidebar)
        matcher.resetToDefaults()

        XCTAssertEqual(matcher.bindings, Keybinding.defaults)
    }
}
