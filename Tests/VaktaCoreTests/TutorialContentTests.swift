//
//  TutorialContentTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the welcome tour: each step shows the user's
//  actual shortcut (their chord, else their leader sequence when leader keys
//  are on, else none so the view falls back to the ⌘K/menu wording), and
//  Next/Back/Skip navigation.
//

import AppKit
import XCTest
@testable import Vakta

final class TutorialContentTests: XCTestCase {
    private let leaderOn = LeaderSettings(isEnabled: true)
    private let leaderOff = LeaderSettings(isEnabled: false)

    private var leaderChord: String {
        Keybinding.displayString(modifierMask: leaderOn.modifierMask, keyCode: leaderOn.keyCode)
    }

    // MARK: Shortcut labels

    func test_boundCommand_showsItsChord() {
        let label = TutorialShortcut.label(
            for: .openSessionSwitcher, bindings: Keybinding.defaults, leader: leaderOff, leaderSequences: [:])
        XCTAssertEqual(label, "⌘K")
    }

    func test_reboundCommand_showsTheUsersChord() {
        let rebound = [Keybinding(modifierMask: [.command, .shift], keyCode: Keybinding.kKeyCode, action: .openSessionSwitcher)]
        let label = TutorialShortcut.label(for: .openSessionSwitcher, bindings: rebound, leader: leaderOff, leaderSequences: [:])
        XCTAssertEqual(label, rebound[0].displayString)
    }

    func test_unboundCommand_withLeaderEnabled_showsLeaderThenSequence() {
        let label = TutorialShortcut.label(
            for: .newSession, bindings: [], leader: leaderOn, leaderSequences: [.newSession: "s n"])
        XCTAssertEqual(label, "\(leaderChord) s n")
    }

    func test_unboundCommand_withLeaderDisabled_hasNoLabel() {
        let label = TutorialShortcut.label(
            for: .newSession, bindings: [], leader: leaderOff, leaderSequences: [.newSession: "s n"])
        XCTAssertNil(label)
    }

    func test_unboundCommand_withoutALeaderSequence_hasNoLabel() {
        XCTAssertNil(TutorialShortcut.label(for: .newSession, bindings: [], leader: leaderOn, leaderSequences: [:]))
    }

    func test_chordWinsOverLeaderSequence() {
        let bindings = [Keybinding(modifierMask: [.command], keyCode: Keybinding.kKeyCode, action: .newSession)]
        let label = TutorialShortcut.label(
            for: .newSession, bindings: bindings, leader: leaderOn, leaderSequences: [.newSession: "s n"])
        XCTAssertEqual(label, bindings[0].displayString)
    }

    // MARK: Steps

    func test_steps_coverTheTourInOrder() {
        let steps = TutorialContent.steps(bindings: Keybinding.defaults, leader: leaderOff, leaderSequences: [:])
        XCTAssertEqual(steps.map(\.id), [.welcome, .multiplexerSetup, .commandPalette, .sessions, .panes, .leaderKeys, .fileSidebar, .preferences])
    }

    func test_steps_carryResolvedShortcuts() {
        let steps = TutorialContent.steps(bindings: Keybinding.defaults, leader: leaderOff, leaderSequences: [:])
        let byID = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        XCTAssertEqual(byID[.commandPalette]?.shortcut, "⌘K")
        XCTAssertEqual(byID[.preferences]?.shortcut, "⌘,")
        XCTAssertNil(byID[.welcome]?.shortcut)
    }

    func test_leaderStep_showsTheLeaderChordOnlyWhenEnabled() {
        let off = TutorialContent.steps(bindings: [], leader: leaderOff, leaderSequences: [:])
        XCTAssertNil(off.first { $0.id == .leaderKeys }?.shortcut)

        let on = TutorialContent.steps(bindings: [], leader: leaderOn, leaderSequences: [:])
        XCTAssertEqual(on.first { $0.id == .leaderKeys }?.shortcut, leaderChord)
    }

    func test_everyStep_hasTitleAndBody() {
        for step in TutorialContent.steps(bindings: [], leader: leaderOff, leaderSequences: [:]) {
            XCTAssertFalse(step.title.isEmpty, "\(step.id) has no title")
            XCTAssertFalse(step.body.isEmpty, "\(step.id) has no body")
        }
    }

    // MARK: Navigation

    func test_next_advancesWithinTheTour() {
        XCTAssertEqual(TutorialNavigation.next(from: 0, stepCount: 3), .step(1))
    }

    func test_next_onLastStep_finishes() {
        XCTAssertEqual(TutorialNavigation.next(from: 2, stepCount: 3), .finished)
    }

    func test_next_withNoSteps_finishes() {
        XCTAssertEqual(TutorialNavigation.next(from: 0, stepCount: 0), .finished)
    }

    func test_previous_movesBack_andStopsAtTheFirstStep() {
        XCTAssertEqual(TutorialNavigation.previous(from: 2), 1)
        XCTAssertEqual(TutorialNavigation.previous(from: 0), 0)
    }
}
