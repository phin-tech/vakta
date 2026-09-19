//
//  SessionSwitcherPanelTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `SessionSwitcherPanel.sendEvent` actually defers to
//  an in-progress IME composition (not just that `SessionSwitcherKeyRouter`'s
//  pure math looks right -- see KeybindingRoutingTests). Drives a real
//  `NSTextView.setMarkedText` composition -- the same `NSTextInputClient`
//  call a real input method issues -- rather than a fake/mock marked-text
//  flag.

import AppKit
import XCTest
@testable import Vakta

@MainActor
final class SessionSwitcherPanelTests: XCTestCase {
    private func keyDownEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
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

    private func makeModel() -> SessionSwitcherModel {
        let model = SessionSwitcherModel()
        model.reset(items: [
            PaletteItem(id: "alpha", title: "alpha", subtitle: nil, category: .session, status: .idle, kind: .selectSession(UUID())),
            PaletteItem(id: "beta", title: "beta", subtitle: nil, category: .session, status: .idle, kind: .selectSession(UUID()))
        ])
        return model
    }

    func test_downArrow_noMarkedText_movesHighlight() {
        let panel = SessionSwitcherPanel()
        let model = makeModel()
        panel.model = model
        panel.hasMarkedTextProvider = { false }

        panel.sendEvent(keyDownEvent(keyCode: 125))

        XCTAssertEqual(model.highlighted, 1)
    }

    func test_downArrow_realMarkedTextComposition_doesNotMoveHighlight() {
        let panel = SessionSwitcherPanel()
        let model = makeModel()
        panel.model = model

        let composingTextView = NSTextView(frame: .zero)
        // A real IME issues exactly this NSTextInputClient call to start a
        // composition (e.g. an unconfirmed Japanese/Chinese candidate).
        composingTextView.setMarkedText("か", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(composingTextView.hasMarkedText(), "setup: the real NSTextView must actually be composing")
        panel.hasMarkedTextProvider = { composingTextView.hasMarkedText() }

        panel.sendEvent(keyDownEvent(keyCode: 125))

        XCTAssertEqual(model.highlighted, 0, "the arrow key must reach the composing field, not move the switcher's own highlight")
    }

    func test_return_realMarkedTextComposition_doesNotCommitSelection() {
        let panel = SessionSwitcherPanel()
        let model = makeModel()
        panel.model = model
        var selected: PaletteItem?
        model.onSelect = { selected = $0 }

        let composingTextView = NSTextView(frame: .zero)
        composingTextView.setMarkedText("か", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 0, length: 0))
        panel.hasMarkedTextProvider = { composingTextView.hasMarkedText() }

        panel.sendEvent(keyDownEvent(keyCode: 36))

        XCTAssertNil(selected, "Return must confirm the IME composition, not commit the switcher's highlighted session")
    }

    func test_shiftDownArrow_noMarkedText_doesNotMoveHighlight() {
        let panel = SessionSwitcherPanel()
        let model = makeModel()
        panel.model = model
        panel.hasMarkedTextProvider = { false }

        panel.sendEvent(keyDownEvent(keyCode: 125, modifiers: .shift))

        XCTAssertEqual(model.highlighted, 0, "⇧↓ must reach the search field's text selection, not move the switcher's highlight")
    }

    func test_return_noMarkedText_commitsHighlightedSelection() {
        let panel = SessionSwitcherPanel()
        let model = makeModel()
        panel.model = model
        panel.hasMarkedTextProvider = { false }
        var selected: PaletteItem?
        model.onSelect = { selected = $0 }

        panel.sendEvent(keyDownEvent(keyCode: 36))

        XCTAssertEqual(selected, model.matches[0])
    }

    func test_tab_noMarkedText_requestsDrillDown() {
        let panel = SessionSwitcherPanel()
        let model = makeModel()
        panel.model = model
        panel.hasMarkedTextProvider = { false }
        var intent: PaletteNavigationIntent?
        model.onNavigation = { intent = $0 }

        panel.sendEvent(keyDownEvent(keyCode: 48))

        XCTAssertEqual(intent, .tab)
    }

    func test_shiftTab_noMarkedText_requestsBack() {
        let panel = SessionSwitcherPanel()
        let model = makeModel()
        panel.model = model
        panel.hasMarkedTextProvider = { false }
        var intent: PaletteNavigationIntent?
        model.onNavigation = { intent = $0 }

        panel.sendEvent(keyDownEvent(keyCode: 48, modifiers: .shift))

        XCTAssertEqual(intent, .shiftTab)
    }
}
