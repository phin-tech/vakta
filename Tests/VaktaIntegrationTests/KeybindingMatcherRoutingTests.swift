//
//  KeybindingMatcherRoutingTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `KeybindingMatcher.handle` actually defers to a
//  text-editing first responder for contextSensitive actions (not just that
//  `KeybindingRoutingPlanner`'s pure math looks right -- see
//  KeybindingRoutingTests), and that `setBinding` commits in one snapshot.
//  Uses a real, standalone `NSTextView` as the focused context and a real
//  synthesized `NSEvent` -- no window, no key-window status, and no mocks.

import AppKit
import Combine
import XCTest
@testable import Vakta

@MainActor
final class KeybindingMatcherRoutingTests: XCTestCase {
    private var tempDirectory: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybindingMatcherRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func keyDownEvent(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func test_matchedContextSensitiveAction_noTextEntryFocused_consumesAndFires() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.setBinding(.command, keyCode: 7, for: .toggleSidebar)
        matcher.firstResponderProvider = { nil }

        var fired: KeybindingAction?
        let result = matcher.handle(keyDownEvent(modifiers: .command, keyCode: 7)) { fired = $0 }

        XCTAssertNil(result, "a consumed event must return nil so AppKit dispatch stops here")
        XCTAssertEqual(fired, .toggleSidebar)
    }

    func test_matchedContextSensitiveAction_realTextViewFocused_fallsThroughUnfired() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        // ⌘V: a chord a user could plausibly record for a session action,
        // and also standard paste -- the exact collision the ticket's
        // evidence describes.
        matcher.setBinding(.command, keyCode: 9, for: .selectSession(2))
        let realTextView = NSTextView(frame: .zero)
        matcher.firstResponderProvider = { realTextView }

        var fired: KeybindingAction?
        let event = keyDownEvent(modifiers: .command, keyCode: 9)
        let result = matcher.handle(event) { fired = $0 }

        XCTAssertNotNil(result, "must fall through to the focused text view's own ⌘V/paste handling")
        XCTAssertNil(fired, "the session-select action must not fire while a text field is being edited")
    }

    func test_globalQuitAction_realTextViewFocused_stillConsumesAndFires() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.setBinding(.command, keyCode: 12, for: .quit)
        let realTextView = NSTextView(frame: .zero)
        matcher.firstResponderProvider = { realTextView }

        var fired: KeybindingAction?
        let result = matcher.handle(keyDownEvent(modifiers: .command, keyCode: 12)) { fired = $0 }

        XCTAssertNil(result, "quit must remain reachable even while a text field has focus")
        XCTAssertEqual(fired, .quit)
    }

    func test_unmatchedKey_realTextViewFocused_fallsThrough() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.firstResponderProvider = { NSTextView(frame: .zero) }

        var fired: KeybindingAction?
        let result = matcher.handle(keyDownEvent(modifiers: [], keyCode: 0)) { fired = $0 }

        XCTAssertNotNil(result)
        XCTAssertNil(fired)
    }

    // MARK: - setBinding: chord conflicts, modifier normalization, one-snapshot commit

    func test_setBinding_stealingAnotherActionsChord_unbindsThatOtherAction() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.setBinding(.command, keyCode: 1, for: .toggleSidebar)

        matcher.setBinding(.command, keyCode: 1, for: .openPreferences)

        XCTAssertEqual(matcher.binding(for: .openPreferences)?.keyCode, 1)
        XCTAssertNil(matcher.binding(for: .toggleSidebar), "the chord's previous owner must be unbound, not left shadowed")
    }

    func test_setBinding_normalizesIrrelevantModifierFlagsOutOfTheStoredMask() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        // `.numericPad`/`.function` are real `NSEvent.ModifierFlags` members
        // that can show up on `event.modifierFlags` (e.g. from an arrow key)
        // but are excluded from matching -- a caller passing them through
        // unnormalized must not silently store a chord that can then never
        // match a real event's already-intersected `mods`.
        matcher.setBinding([.command, .numericPad, .function], keyCode: 3, for: .toggleSidebar)

        XCTAssertEqual(matcher.binding(for: .toggleSidebar)?.modifierMask, .command)
    }

    func test_setBinding_publishesExactlyOneChange_notASeparateRemoveThenAppend() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.setBinding(.command, keyCode: 1, for: .toggleSidebar)

        var emissionCount = 0
        matcher.$bindings
            .dropFirst() // the subscription's initial replay
            .sink { _ in emissionCount += 1 }
            .store(in: &cancellables)

        matcher.setBinding(.shift, keyCode: 2, for: .toggleSidebar)

        XCTAssertEqual(
            emissionCount, 1,
            "rebinding an action (which both removes its old chord and adds the new one) " +
            "must commit as one snapshot, not two separately-observable mutations"
        )
    }

    // MARK: - Recording ownership

    func test_cancelCaptureWhenResigningKey_windowResignsKey_dropsThePendingCapture() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        matcher.cancelCaptureWhenResigningKey(from: window)
        matcher.captureNext = { _ in XCTFail("a stale capture must not receive a key") }

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        XCTAssertNil(matcher.captureNext)
    }

    func test_cancelCaptureWhenResigningKey_aDifferentWindowResigningKey_doesNotDropTheCapture() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        let ownedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let unrelatedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        matcher.cancelCaptureWhenResigningKey(from: ownedWindow)
        var captured: NSEvent?
        matcher.captureNext = { captured = $0 }

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: unrelatedWindow)
        XCTAssertNotNil(matcher.captureNext, "only the owning window's resignation should cancel the capture")

        let event = keyDownEvent(modifiers: .command, keyCode: 1)
        _ = matcher.handle(event) { _ in }
        XCTAssertTrue(captured === event)
    }

    func test_isCapturing_tracksCaptureNext_includingAnExternalCancel() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        var observed: [Bool] = []
        matcher.$isCapturing
            .sink { observed.append($0) }
            .store(in: &cancellables)

        matcher.captureNext = { _ in }
        matcher.cancelCapture()

        XCTAssertEqual(observed, [false, true, false])
    }
}
