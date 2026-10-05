//
//  PanelCallbacksTests.swift
//  VaktaCoreTests
//
//  Buttons and Effects: one Callback in flight per button, failures cleared
//  by the next render, Effects planned in order with stale view Effects
//  dropped and unsafe URLs skipped, shortcut parsing, and push/pop/replace
//  navigation in the Panel View.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class PanelCallbacksTests: XCTestCase {
    private func button(_ callback: String, payload: JSONValue? = nil) -> ViewButton {
        ViewButton(title: callback, symbol: nil, callback: callback, payload: payload, style: .default, confirm: nil, shortcut: nil)
    }

    // MARK: - Tracker

    func test_key_distinguishesViewCallbackAndPayload_butNotTitle() {
        let claimA = CallbackKey(view: "issues", button: button("claim", payload: .object(["id": .string("a")])))
        var retitled = button("claim", payload: .object(["id": .string("a")]))
        retitled.title = "Claim it"
        XCTAssertEqual(claimA, CallbackKey(view: "issues", button: retitled))
        XCTAssertNotEqual(claimA, CallbackKey(view: "issues", button: button("claim", payload: .object(["id": .string("b")]))))
        XCTAssertNotEqual(claimA, CallbackKey(view: "other", button: button("claim", payload: .object(["id": .string("a")]))))
        XCTAssertNotEqual(claimA, CallbackKey(view: "issues", button: button("close", payload: .object(["id": .string("a")]))))
    }

    func test_tracker_allowsOneInFlightPerButton() {
        var tracker = CallbackTracker()
        let claim = CallbackKey(view: "issues", button: button("claim"))
        let close = CallbackKey(view: "issues", button: button("close"))

        XCTAssertTrue(tracker.begin(claim))
        XCTAssertFalse(tracker.begin(claim), "a second press while pending is ignored")
        XCTAssertTrue(tracker.begin(close), "other buttons are independent")
        XCTAssertEqual(tracker.state(claim), .pending)

        tracker.succeed(claim)
        XCTAssertEqual(tracker.state(claim), .idle)
        XCTAssertTrue(tracker.begin(claim))
    }

    func test_tracker_failureShowsUntilTheNextRender_andAllowsRetry() {
        var tracker = CallbackTracker()
        let claim = CallbackKey(view: "issues", button: button("claim"))
        _ = tracker.begin(claim)

        tracker.fail(claim, "already owned")
        XCTAssertEqual(tracker.state(claim), .failed("already owned"))
        XCTAssertTrue(tracker.begin(claim), "a failed button can be pressed again")
        tracker.fail(claim, "still owned")

        tracker.clearFailures()
        XCTAssertEqual(tracker.state(claim), .idle)
    }

    func test_tracker_clearFailures_keepsPendingButtons() {
        var tracker = CallbackTracker()
        let claim = CallbackKey(view: "issues", button: button("claim"))
        _ = tracker.begin(claim)
        tracker.clearFailures()
        XCTAssertEqual(tracker.state(claim), .pending)
    }

    // MARK: - Effects

    private let list = ViewDocument.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: []))

    func test_plan_keepsOrder() {
        XCTAssertEqual(
            EffectPlanner.plan([
                .toast(text: "Claimed"), .refresh, .push(list), .pop, .replace(list),
                .notify(title: "Done", body: nil), .openURL("https://example.com/pr/3"),
                .openPane(cwd: "/r", command: ["claude", "go"], title: "fcae"),
                .openSession(cwd: nil, command: ["kata", "tui"], title: nil), .copyText("link"),
            ], isStale: false),
            [
                .toast("Claimed"), .refresh, .push(list), .pop, .replace(list),
                .notify(title: "Done", body: nil), .openURL(URL(string: "https://example.com/pr/3")!),
                .openPane(cwd: "/r", command: ["claude", "go"], title: "fcae"),
                .openSession(cwd: nil, command: ["kata", "tui"], title: nil), .copy("link"),
            ]
        )
    }

    func test_plan_whenStale_dropsViewEffects_butKeepsMessagesAndLaunches() {
        XCTAssertEqual(
            EffectPlanner.plan([
                .refresh, .toast(text: "Claimed"), .push(list), .pop, .replace(list),
                .notify(title: "Done", body: "b"), .openPane(cwd: nil, command: ["claude"], title: nil),
            ], isStale: true),
            [.toast("Claimed"), .notify(title: "Done", body: "b"), .openPane(cwd: nil, command: ["claude"], title: nil)]
        )
    }

    func test_plan_skipsUnsupportedEffectsAndUnsafeURLs() {
        XCTAssertEqual(
            EffectPlanner.plan([
                .unsupported(type: "confetti"),
                .openURL("file:///etc/passwd"), .openURL("javascript:alert(1)"), .openURL("not a url"),
                .openURL("http://localhost:3000"),
            ], isStale: false),
            [.openURL(URL(string: "http://localhost:3000")!)]
        )
    }

    // MARK: - Shortcuts

    func test_parseShortcut() {
        XCTAssertEqual(ButtonShortcut.parse("return"), ButtonShortcut(key: .return, modifiers: []))
        XCTAssertEqual(ButtonShortcut.parse("cmd+return"), ButtonShortcut(key: .return, modifiers: .command))
        XCTAssertEqual(ButtonShortcut.parse("Cmd+Shift+K"), ButtonShortcut(key: .character("k"), modifiers: [.command, .shift]))
        XCTAssertEqual(ButtonShortcut.parse("ctrl+opt+backspace"), ButtonShortcut(key: .delete, modifiers: [.control, .option]))
        XCTAssertEqual(ButtonShortcut.parse("cmd+backspace"), ButtonShortcut(key: .delete, modifiers: .command))
        XCTAssertEqual(ButtonShortcut.parse("space"), ButtonShortcut(key: .space, modifiers: []))
        XCTAssertEqual(ButtonShortcut.parse("up"), ButtonShortcut(key: .up, modifiers: []))
    }

    func test_parseShortcut_rejectsNonsense() {
        for text in ["", "cmd", "cmd+", "+k", "hyper+k", "cmd+ab", "cmd+k+j"] {
            XCTAssertNil(ButtonShortcut.parse(text), text)
        }
    }

    func test_shortcutSymbol() {
        XCTAssertEqual(ButtonShortcut.parse("cmd+return")?.symbol, "⌘↩")
        XCTAssertEqual(ButtonShortcut.parse("ctrl+opt+shift+cmd+k")?.symbol, "⌃⌥⇧⌘K")
        XCTAssertEqual(ButtonShortcut.parse("backspace")?.symbol, "⌫")
    }

    // MARK: - Navigation

    private func item(_ id: String, detail: String?) -> ListItem {
        ListItem(id: id, title: id, subtitle: nil, symbol: nil, accessories: [],
                 detail: detail.map { .detail(DetailView(title: $0, markdown: nil, fields: [], buttons: [])) }, buttons: [])
    }

    private func detail(_ title: String) -> ViewDocument {
        .detail(DetailView(title: title, markdown: nil, fields: [], buttons: []))
    }

    func test_push_showsTheDocument_andPopReturns() {
        var model = PanelViewModel()
        let root = ViewDocument.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [ListSection(title: nil, items: [item("a", detail: "A")])]))
        model.apply(root, generation: model.beginRender())
        model.openDetail("a")

        model.push(detail("Pushed"))
        XCTAssertEqual(model.visibleDocument, detail("Pushed"))
        XCTAssertTrue(model.isShowingDetail)

        model.back()
        XCTAssertEqual(model.visibleDocument, detail("A"))
        model.back()
        XCTAssertEqual(model.visibleDocument, root)
        XCTAssertFalse(model.isShowingDetail)
    }

    func test_replaceVisible_replacesThePushedDocument_orTheRoot() {
        var model = PanelViewModel()
        let root = ViewDocument.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: []))
        model.apply(root, generation: model.beginRender())

        model.push(detail("One"))
        model.replaceVisible(detail("Two"))
        XCTAssertEqual(model.visibleDocument, detail("Two"))
        model.back()
        XCTAssertEqual(model.visibleDocument, root)

        model.replaceVisible(detail("New root"))
        XCTAssertEqual(model.visibleDocument, detail("New root"))
        XCTAssertFalse(model.isShowingDetail)
    }

    func test_pushedDocuments_surviveALiveUpdateOfTheRoot() {
        var model = PanelViewModel()
        model.apply(.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [])), generation: model.beginRender())
        model.push(detail("Form"))

        model.apply(.list(ListView(title: "v2", searchPlaceholder: nil, emptyText: nil, sections: [])), generation: model.generation)

        XCTAssertEqual(model.visibleDocument, detail("Form"))
    }
}
