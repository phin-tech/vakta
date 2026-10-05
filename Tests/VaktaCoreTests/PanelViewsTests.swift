//
//  PanelViewsTests.swift
//  VaktaCoreTests
//
//  The right panel's Extension modes: persistence of the mode, fallback
//  when the Extension isn't available, toggle overflow, and the Panel
//  View's own state (stale results, filtering, detail navigation that
//  survives live updates).

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class PanelViewsTests: XCTestCase {
    private let issues = PanelViewRef(extensionID: "kata", viewID: "issues")

    // MARK: - Mode persistence

    private func decodeMode(_ json: String) throws -> FileSidebarMode {
        try JSONDecoder().decode(FileSidebarPreferences.self, from: Data(json.utf8)).mode
    }

    func test_extensionMode_roundTripsAsAString() throws {
        let preferences = FileSidebarPreferences(isVisible: true, width: 300, mode: .extensionView(issues))
        let data = try JSONEncoder().encode(preferences)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""mode":"extension:kata\/issues""#))
        XCTAssertEqual(try JSONDecoder().decode(FileSidebarPreferences.self, from: data), preferences)
    }

    func test_legacyModes_stillDecode() throws {
        XCTAssertEqual(try decodeMode(#"{"mode": "files"}"#), .files)
        XCTAssertEqual(try decodeMode(#"{"mode": "changes"}"#), .changes)
    }

    func test_malformedExtensionMode_fallsBackToFiles() throws {
        for mode in ["extension:", "extension:kata", "extension:/issues", "extension:kata/", "plugin:kata/issues"] {
            XCTAssertEqual(try decodeMode(#"{"mode": "\#(mode)"}"#), .files, mode)
        }
    }

    // MARK: - Fallback and toggle

    private func option(_ id: String, view: String = "v") -> PanelViewOption {
        PanelViewOption(ref: PanelViewRef(extensionID: id, viewID: view), title: id, symbol: "circle")
    }

    func test_effectiveMode_showsFilesWhenTheSavedViewIsUnavailable() {
        let kata = PanelViewOption(ref: issues, title: "Issues", symbol: "checklist")
        XCTAssertEqual(PanelModeResolver.effectiveMode(saved: .extensionView(issues), available: [kata]), .extensionView(issues))
        XCTAssertEqual(PanelModeResolver.effectiveMode(saved: .extensionView(issues), available: []), .files)
        XCTAssertEqual(PanelModeResolver.effectiveMode(saved: .changes, available: []), .changes)
        XCTAssertEqual(PanelModeResolver.effectiveMode(saved: .files, available: [kata]), .files)
    }

    func test_options_comeFromReadyEntriesOnly_inLinkOrder() {
        func entry(_ id: String, _ status: ExtensionStatus, views: [String]) -> ExtensionEntry {
            ExtensionEntry(
                record: LinkedExtensionRecord(directory: "/x/\(id)", enabled: true, developerMode: false, approved: nil),
                manifest: ExtensionManifest(
                    id: id, name: id, description: nil, command: ["./run"], build: [],
                    panelViews: views.map { .init(id: $0, title: $0.capitalized, symbol: "circle") }
                ),
                status: status
            )
        }
        let options = PanelModeResolver.options(from: [
            entry("kata", .ready, views: ["issues", "ready"]),
            entry("gh", .needsApproval(.neverApproved), views: ["prs"]),
            entry("notes", .disabled, views: ["notes"]),
            entry("todo", .ready, views: ["todo"]),
        ])
        XCTAssertEqual(options.map(\.ref), [
            PanelViewRef(extensionID: "kata", viewID: "issues"),
            PanelViewRef(extensionID: "kata", viewID: "ready"),
            PanelViewRef(extensionID: "todo", viewID: "todo"),
        ])
        XCTAssertEqual(options.first?.title, "Issues")
    }

    func test_split_keepsTwoInline_andOverflowsTheRest() {
        let options = ["a", "b", "c", "d"].map { option($0) }
        let split = PanelModeResolver.split(options)
        XCTAssertEqual(split.inline.map(\.title), ["a", "b"])
        XCTAssertEqual(split.overflow.map(\.title), ["c", "d"])
        XCTAssertEqual(PanelModeResolver.split([option("a")]).overflow, [])
    }

    // MARK: - Panel View state

    private func item(_ id: String, _ title: String, subtitle: String? = nil, tag: String? = nil, detail: String? = nil) -> ListItem {
        ListItem(
            id: id, title: title, subtitle: subtitle, symbol: nil,
            accessories: tag.map { [Accessory(text: $0, symbol: nil)] } ?? [],
            detail: detail.map { .detail(DetailView(title: $0, markdown: nil, fields: [], buttons: [])) },
            buttons: []
        )
    }

    private func list(_ sections: [(String?, [ListItem])]) -> ViewDocument {
        .list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: sections.map { ListSection(title: $0.0, items: $0.1) }))
    }

    func test_apply_fromTheCurrentGeneration_showsTheDocument() {
        var model = PanelViewModel()
        XCTAssertEqual(model.content, .loading)
        let generation = model.beginRender()
        let document = list([("Ready", [item("a", "Alpha")])])

        XCTAssertTrue(model.apply(document, generation: generation))
        XCTAssertEqual(model.content, .document(document))
        XCTAssertEqual(model.visibleDocument, document)
    }

    /// A `view/update` push and a `view/render` response can race (the
    /// extension answers a render, then immediately pushes, before Vakta
    /// reads the response). The push must win: the stale render response
    /// arriving after it must not overwrite the pushed document.
    func test_aPushThatLandsWhileARenderIsInFlight_invalidatesTheRendersStaleResponse() {
        var model = PanelViewModel()
        let renderToken = model.beginRender()
        let pushed = list([("Pushed", [item("a", "Alpha")])])
        let staleRenderResponse = list([("Stale", [item("b", "Beta")])])

        XCTAssertTrue(model.applyPush(pushed), "the push applies immediately")
        XCTAssertEqual(model.content, .document(pushed))

        XCTAssertFalse(
            model.apply(staleRenderResponse, generation: renderToken),
            "a render response captured before the push began must not overwrite it"
        )
        XCTAssertEqual(model.content, .document(pushed))
    }

    func test_resultsFromBeforeAReset_areDropped() {
        var model = PanelViewModel()
        let old = model.beginRender()
        model.reset()
        let current = model.beginRender()

        XCTAssertFalse(model.apply(list([("Old", [])]), generation: old))
        model.fail("old failure", generation: old)
        XCTAssertEqual(model.content, .loading)

        XCTAssertTrue(model.apply(list([("New", [])]), generation: current))
    }

    func test_reloading_keepsTheCurrentDocumentOnScreen() {
        var model = PanelViewModel()
        let document = list([("Ready", [item("a", "Alpha")])])
        model.apply(document, generation: model.beginRender())

        _ = model.beginRender()

        XCTAssertEqual(model.content, .document(document))
    }

    func test_failAndUnavailable() {
        var model = PanelViewModel()
        model.fail("kata: boom", generation: model.beginRender())
        XCTAssertEqual(model.content, .error("kata: boom"))

        model.markUnavailable("Kata stopped")
        XCTAssertEqual(model.content, .unavailable("Kata stopped"))
        XCTAssertNil(model.visibleDocument)
    }

    func test_filter_matchesTitleSubtitleIdAndAccessories_caseInsensitively_andDropsEmptySections() {
        let source = ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [
            ListSection(title: "Ready", items: [item("fcae", "Protocol kit", subtitle: "P2"), item("7cq8", "Trust", tag: "extensions")]),
            ListSection(title: "Blocked", items: [item("hkkb", "Supervisor")]),
        ])
        func ids(_ query: String) -> [[String]] {
            PanelViewModel.filter(source, query: query).sections.map { $0.items.map(\.id) }
        }
        XCTAssertEqual(ids(""), [["fcae", "7cq8"], ["hkkb"]])
        XCTAssertEqual(ids("  "), [["fcae", "7cq8"], ["hkkb"]])
        XCTAssertEqual(ids("PROTOCOL"), [["fcae"]])
        XCTAssertEqual(ids("p2"), [["fcae"]])
        XCTAssertEqual(ids("hkk"), [["hkkb"]])
        XCTAssertEqual(ids("EXTENSIONS"), [["7cq8"]])
        XCTAssertEqual(ids("nothing"), [])
    }

    func test_filteredList_appliesTheModelFilter() {
        var model = PanelViewModel()
        model.apply(list([("Ready", [item("a", "Alpha"), item("b", "Beta")])]), generation: model.beginRender())
        model.filter = "bet"
        XCTAssertEqual(model.filteredList?.sections.first?.items.map(\.id), ["b"])
    }

    func test_openDetail_showsTheItemsDetail_andBackReturns() {
        var model = PanelViewModel()
        let document = list([("Ready", [item("a", "Alpha", detail: "Alpha detail"), item("b", "Beta")])])
        model.apply(document, generation: model.beginRender())

        model.openDetail("a")
        XCTAssertEqual(model.selectedItemID, "a")
        XCTAssertEqual(model.visibleDocument, .detail(DetailView(title: "Alpha detail", markdown: nil, fields: [], buttons: [])))

        model.back()
        XCTAssertEqual(model.visibleDocument, document)
        XCTAssertEqual(model.selectedItemID, "a", "back keeps the selection")

        model.openDetail("b")
        XCTAssertEqual(model.visibleDocument, document, "an item without detail opens nothing")
        XCTAssertEqual(model.selectedItemID, "b")
    }

    func test_liveUpdate_refreshesTheOpenDetail_andClosesItWhenTheItemIsGone() {
        var model = PanelViewModel()
        model.apply(list([("Ready", [item("a", "Alpha", detail: "v1")])]), generation: model.beginRender())
        model.openDetail("a")

        model.apply(list([("Ready", [item("a", "Alpha", detail: "v2")])]), generation: model.generation)
        XCTAssertEqual(model.visibleDocument, .detail(DetailView(title: "v2", markdown: nil, fields: [], buttons: [])))

        let without = list([("Ready", [item("z", "Zed")])])
        model.apply(without, generation: model.generation)
        XCTAssertEqual(model.visibleDocument, without)
        XCTAssertNil(model.selectedItemID)
    }

    func test_reset_clearsNavigationAndFilter() {
        var model = PanelViewModel()
        model.apply(list([("Ready", [item("a", "Alpha", detail: "d")])]), generation: model.beginRender())
        model.openDetail("a")
        model.filter = "al"

        model.reset()

        XCTAssertNil(model.selectedItemID)
        XCTAssertEqual(model.filter, "")
        XCTAssertEqual(model.content, .loading)
    }

    func test_resetShowingCached_showsItImmediately_andStillDropsStaleResults() {
        var model = PanelViewModel()
        let old = model.beginRender()
        let cached = list([("Cached", [item("c", "Cached", detail: "d")])])

        model.reset(showing: cached)

        XCTAssertEqual(model.content, .document(cached))
        XCTAssertFalse(model.apply(list([("Stale", [])]), generation: old), "results from before the switch are dropped")
        XCTAssertEqual(model.content, .document(cached))
        let fresh = list([("Fresh", [])])
        XCTAssertTrue(model.apply(fresh, generation: model.beginRender()))
        XCTAssertEqual(model.content, .document(fresh))
    }

    func test_resetShowingCached_clearsNavigationAndFilter() {
        var model = PanelViewModel()
        model.apply(list([("Ready", [item("a", "Alpha", detail: "d")])]), generation: model.beginRender())
        model.openDetail("a")
        model.filter = "al"

        model.reset(showing: list([("Other", [])]))

        XCTAssertFalse(model.isShowingDetail)
        XCTAssertNil(model.selectedItemID)
        XCTAssertEqual(model.filter, "")
    }
}
