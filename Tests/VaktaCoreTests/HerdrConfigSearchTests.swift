//
//  HerdrConfigSearchTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for searching the herdr config editor's settings and
//  key bindings. Pure.

import XCTest
@testable import Vakta

final class HerdrConfigSearchTests: XCTestCase {
    private func paths(_ query: String) -> [String] {
        HerdrConfigSearch.settings(matching: query).map(\.path)
    }

    private func actions(_ query: String, document: HerdrConfigDocument = HerdrConfigDocument(text: "")) -> [String] {
        HerdrConfigSearch.keyActions(matching: query, in: document).map(\.name)
    }

    func test_emptyOrWhitespaceQuery_matchesNothingSoTheUIShowsTheNormalTabs() {
        XCTAssertFalse(HerdrConfigSearch.isActive(""))
        XCTAssertFalse(HerdrConfigSearch.isActive("   "))
        XCTAssertTrue(HerdrConfigSearch.isActive("toast"))
    }

    func test_settings_matchByLabelCaseInsensitively() {
        XCTAssertTrue(paths("TAB BAR").contains("ui.tab_bar_position"))
    }

    func test_settings_matchByRawKeyPath_withOrWithoutDotsAndUnderscores() {
        XCTAssertTrue(paths("ui.toast.delivery").contains("ui.toast.delivery"))
        XCTAssertTrue(paths("toast delivery").contains("ui.toast.delivery"))
        XCTAssertTrue(paths("headless_cols").contains("server.headless_cols"))
    }

    func test_settings_matchByHelpTextAndGroupTitle() {
        XCTAssertTrue(paths("kitty-compatible").contains("terminal.kitty_graphics"))
        XCTAssertTrue(paths("Notifications").contains("ui.toast.delay_seconds"))
    }

    func test_settings_multiWordQuery_requiresEveryWord() {
        let results = paths("toast position")
        XCTAssertTrue(results.contains("ui.toast.herdr.position"))
        XCTAssertFalse(results.contains("ui.toast.delay_seconds"))
    }

    func test_settings_noMatch_isEmpty() {
        XCTAssertEqual(paths("zzzzqqq"), [])
    }

    func test_settings_resultsKeepCatalogOrder() {
        let all = HerdrConfigCatalog.entries.map(\.path)
        let found = paths("toast")
        XCTAssertEqual(found, all.filter(found.contains))
    }

    func test_keyActions_matchByLabelNameAndDefaultBinding() {
        XCTAssertTrue(actions("split horizontally").contains("split_horizontal"))
        XCTAssertTrue(actions("split_horizontal").contains("split_horizontal"))
        XCTAssertTrue(actions("prefix+minus").contains("split_horizontal"))
    }

    func test_keyActions_matchTheFilesBindingNotJustTheDefault() {
        let doc = HerdrConfigDocument(text: "[keys]\nnew_tab = \"cmd+t\"\n")
        XCTAssertTrue(actions("cmd+t", document: doc).contains("new_tab"))
        XCTAssertFalse(actions("prefix+c", document: doc).contains("new_tab"), "the default no longer applies")
    }

    func test_keyActions_matchByGroupTitle() {
        XCTAssertTrue(actions("navigate mode").contains("navigate_pane_left"))
    }
}
