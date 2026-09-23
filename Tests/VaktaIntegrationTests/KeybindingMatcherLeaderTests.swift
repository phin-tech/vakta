//
//  KeybindingMatcherLeaderTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for leader-key routing through `KeybindingMatcher.handle`:
//  real synthesized `NSEvent`s, a real standalone `NSTextView` for the
//  text-entry case, and a temporary storage root. No mocks -- assertions are
//  on the returned event (consume vs fall-through), the delivered command,
//  the published `leaderPath`, and what survives a restart.

import AppKit
import XCTest
@testable import Vakta

@MainActor
final class KeybindingMatcherLeaderTests: XCTestCase {
    private var tempDirectory: URL!

    private let space: UInt16 = 49
    /// The default leader chord is ⌘/.
    private let slash: UInt16 = 44
    private let w: UInt16 = 13
    private let v: UInt16 = 9
    private let a: UInt16 = 0
    private let escape: UInt16 = 53

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybindingMatcherLeaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func keyDown(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode
        )!
    }

    private func flagsChanged(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 56
        )!
    }

    private func enabledMatcher(supportsActions: Bool = true) -> KeybindingMatcher {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.leaderSettings.isEnabled = true
        matcher.firstResponderProvider = { nil }
        matcher.commandContextProvider = { CommandContext(supportsSelectedSessionActions: supportsActions) }
        return matcher
    }

    /// Feeds `events` in order, returning each `handle` result and every
    /// delivered command.
    private func feed(_ matcher: KeybindingMatcher, _ events: [NSEvent]) -> (results: [NSEvent?], fired: [AppCommand]) {
        var fired: [AppCommand] = []
        let results = events.map { event in matcher.handle(event) { fired.append($0) } }
        return (results, fired)
    }

    func test_flagOff_leaderChordFallsThrough_andNothingIsPending() {
        let matcher = KeybindingMatcher(root: tempDirectory)
        matcher.firstResponderProvider = { nil }

        let (results, fired) = feed(matcher, [keyDown(slash, .command)])

        XCTAssertNotNil(results[0])
        XCTAssertNil(matcher.leaderPath)
        XCTAssertEqual(fired, [])
    }

    func test_flagOn_leaderChordIsConsumed_andStartsAtRoot() {
        let matcher = enabledMatcher()

        let (results, fired) = feed(matcher, [keyDown(slash, .command)])

        XCTAssertNil(results[0])
        XCTAssertEqual(matcher.leaderPath, [])
        XCTAssertEqual(fired, [])
    }

    func test_sequence_deliversTheLeafCommandOnce_consumingEveryKey() {
        let matcher = enabledMatcher()

        let (results, fired) = feed(matcher, [keyDown(slash, .command), keyDown(w), keyDown(v)])

        XCTAssertTrue(results.allSatisfy { $0 == nil }, "no key of a leader sequence may reach the terminal")
        XCTAssertEqual(fired, [.splitPaneRight])
        XCTAssertNil(matcher.leaderPath, "a committed sequence returns to idle")
    }

    func test_workspaceSequence_deliversFocusWorkspace() {
        let matcher = enabledMatcher()
        matcher.commandContextProvider = {
            CommandContext(supportsSelectedSessionActions: true, workspaceTitles: ["guildhall", "notes"])
        }
        let tab: UInt16 = 48, two: UInt16 = 19

        let (results, fired) = feed(matcher, [keyDown(slash, .command), keyDown(tab), keyDown(two)])

        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertEqual(fired, [.focusWorkspace(1)])
    }

    func test_intermediateGroup_isPublishedAsThePendingPath() {
        let matcher = enabledMatcher()
        _ = feed(matcher, [keyDown(slash, .command), keyDown(w)])
        XCTAssertEqual(matcher.leaderPath, [w])
    }

    func test_escape_isConsumedAndCancels() {
        let matcher = enabledMatcher()

        let (results, fired) = feed(matcher, [keyDown(slash, .command), keyDown(w), keyDown(escape)])

        XCTAssertNil(results[2])
        XCTAssertNil(matcher.leaderPath)
        XCTAssertEqual(fired, [])
    }

    func test_unknownKey_isSwallowed_andCancels_thenTheNextKeyIsNormal() {
        let matcher = enabledMatcher()

        let (results, fired) = feed(matcher, [keyDown(slash, .command), keyDown(a), keyDown(a)])

        XCTAssertNil(results[1], "the undefined key is swallowed, Doom-style")
        XCTAssertNotNil(results[2], "after cancelling, keys reach the terminal again")
        XCTAssertNil(matcher.leaderPath)
        XCTAssertEqual(fired, [])
    }

    func test_groupUnavailableForTheSelectedSession_isConsumedAndCancels() {
        let matcher = enabledMatcher(supportsActions: false)

        let (results, fired) = feed(matcher, [keyDown(slash, .command), keyDown(w)])

        XCTAssertNil(results[1])
        XCTAssertNil(matcher.leaderPath)
        XCTAssertEqual(fired, [])
    }

    func test_leaderChord_fallsThrough_whileATextViewIsFocused() {
        let matcher = enabledMatcher()
        let textView = NSTextView(frame: .zero)
        matcher.firstResponderProvider = { textView }

        let (results, _) = feed(matcher, [keyDown(slash, .command)])

        XCTAssertNotNil(results[0])
        XCTAssertNil(matcher.leaderPath)
    }

    func test_leaderChord_fallsThrough_inPassthroughMode() {
        let matcher = enabledMatcher()
        matcher.togglePassthrough()

        let (results, _) = feed(matcher, [keyDown(slash, .command)])

        XCTAssertNotNil(results[0])
        XCTAssertNil(matcher.leaderPath)
    }

    func test_modifierPressWhilePending_fallsThrough_andKeepsTheSequence() {
        let matcher = enabledMatcher()
        _ = feed(matcher, [keyDown(slash, .command), keyDown(w)])

        // ⌥, not ⇧: ⇧ is the default passthrough toggle, and two synthesized
        // events at timestamp 0 would read as its double-tap.
        let (results, _) = feed(matcher, [flagsChanged(.option), flagsChanged([])])

        XCTAssertNotNil(results[0])
        XCTAssertFalse(matcher.passthrough)
        XCTAssertEqual(matcher.leaderPath, [w])
    }

    func test_enteringPassthroughWhilePending_cancelsTheSequence() {
        let matcher = enabledMatcher()
        _ = feed(matcher, [keyDown(slash, .command), keyDown(w)])

        matcher.togglePassthrough()

        XCTAssertNil(matcher.leaderPath)
    }

    func test_disablingTheFlagWhilePending_cancels() {
        let matcher = enabledMatcher()
        _ = feed(matcher, [keyDown(slash, .command)])

        matcher.leaderSettings.isEnabled = false

        XCTAssertNil(matcher.leaderPath)
    }

    func test_cancelLeader_returnsToIdle() {
        let matcher = enabledMatcher()
        _ = feed(matcher, [keyDown(slash, .command), keyDown(w)])

        matcher.cancelLeader()

        XCTAssertNil(matcher.leaderPath)
    }

    func test_setLeaderChord_unbindsAKeybindingOnTheSameChord() {
        let matcher = enabledMatcher()
        matcher.setBinding(.control, keyCode: space, for: .toggleSidebar)

        matcher.setLeaderChord(.control, keyCode: space)

        XCTAssertNil(matcher.binding(for: .toggleSidebar))
        XCTAssertEqual(matcher.leaderSettings.modifierMask, .control)
        XCTAssertEqual(matcher.leaderSettings.keyCode, space)
    }

    func test_setBinding_onTheLeaderChord_isRejectedWhileTheLeaderOwnsIt() {
        // The leader is checked before bindings, so a binding on its chord
        // could never fire; refuse it rather than store a dead binding.
        let matcher = enabledMatcher()

        matcher.setBinding(.command, keyCode: slash, for: .toggleSidebar)

        XCTAssertNil(matcher.binding(for: .toggleSidebar))
    }

    func test_leaderSettings_surviveARestart_butThePendingPathDoesNot() {
        let first = enabledMatcher()
        first.setLeaderChord([.control, .option], keyCode: 40)
        _ = feed(first, [keyDown(40, [.control, .option])])
        XCTAssertEqual(first.leaderPath, [])

        let relaunched = KeybindingMatcher(root: tempDirectory)

        XCTAssertEqual(relaunched.leaderSettings, LeaderSettings(isEnabled: true, modifierMask: [.control, .option], keyCode: 40))
        XCTAssertNil(relaunched.leaderPath)
    }

    func test_hintDelay_survivesARestart() {
        let first = enabledMatcher()
        first.leaderSettings.hintDelayMilliseconds = 0

        let relaunched = KeybindingMatcher(root: tempDirectory)

        XCTAssertEqual(relaunched.leaderSettings.hintDelayMilliseconds, 0)
    }

    func test_corruptLeaderFile_usesDefaultsInMemory_butDoesNotOverwriteIt() throws {
        let store = LeaderSettingsPersistence.store(root: tempDirectory)
        let bytes = Data("{ nope".utf8)
        try bytes.write(to: store.fileURL)

        let matcher = KeybindingMatcher(root: tempDirectory)

        XCTAssertEqual(matcher.leaderSettings, LeaderSettings())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }
}
