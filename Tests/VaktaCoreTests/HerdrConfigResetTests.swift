//
//  HerdrConfigResetTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for bulk "reset to defaults": removing catalog keys
//  from a document while leaving everything the editor doesn't own untouched.

import XCTest
@testable import Vakta

final class HerdrConfigResetTests: XCTestCase {
    private let text = """
    # my config
    onboarding = false
    [keys]
    new_tab = "cmd+t"
    mystery = 1

    [ui]
    confirm_close = false
    tab_bar_position = "bottom"
    future_key = "x"

    [ui.toast]
    delivery = "system"

    [[keys.command]]
    key = "prefix+alt+g"
    type = "popup"
    command = "lazygit"
    """ + "\n"

    func test_resetSettings_all_removesCatalogKeysAndKeepsUnknownKeysCommentsAndCommandBlocks() {
        let reset = HerdrConfigReset.settings(in: HerdrConfigDocument(text: text), group: nil)
        XCTAssertNil(reset.value(at: "ui.confirm_close"))
        XCTAssertNil(reset.value(at: "ui.toast.delivery"))
        XCTAssertEqual(reset.value(at: "ui.future_key"), .string("x"))
        XCTAssertEqual(reset.value(at: "keys.mystery"), .integer(1))
        XCTAssertEqual(reset.value(at: "keys.new_tab"), .string("cmd+t"), "key bindings are not settings")
        XCTAssertTrue(reset.text.hasPrefix("# my config\nonboarding = false\n"))
        XCTAssertEqual(reset.arrayTableEntries("keys.command").count, 1)
    }

    func test_resetSettings_singleGroup_onlyTouchesThatGroup() {
        let reset = HerdrConfigReset.settings(in: HerdrConfigDocument(text: text), group: .notifications)
        XCTAssertNil(reset.value(at: "ui.toast.delivery"))
        XCTAssertEqual(reset.value(at: "ui.confirm_close"), .bool(false))
        XCTAssertEqual(reset.value(at: "ui.tab_bar_position"), .string("bottom"))
    }

    func test_resetKeys_removesBindingsButNotSettingsOrCommandBlocks() {
        let reset = HerdrConfigReset.keys(in: HerdrConfigDocument(text: text), group: nil)
        XCTAssertNil(reset.value(at: "keys.new_tab"))
        XCTAssertEqual(reset.value(at: "keys.mystery"), .integer(1))
        XCTAssertEqual(reset.value(at: "ui.confirm_close"), .bool(false))
        XCTAssertEqual(reset.arrayTableEntries("keys.command"), HerdrConfigDocument(text: text).arrayTableEntries("keys.command"))
    }

    func test_reset_isIdempotentAndNoOpOnACleanDocument() {
        let clean = HerdrConfigDocument(text: "# nothing set\n")
        XCTAssertEqual(HerdrConfigReset.settings(in: clean, group: nil).text, clean.text)
        let once = HerdrConfigReset.settings(in: HerdrConfigDocument(text: text), group: nil)
        XCTAssertEqual(HerdrConfigReset.settings(in: once, group: nil).text, once.text)
    }

    func test_setPaths_reportWhichCatalogKeysAreSetInTheFile_forEnablingResetButtons() {
        let doc = HerdrConfigDocument(text: text)
        XCTAssertEqual(HerdrConfigReset.setSettingPaths(in: doc, group: .notifications), ["ui.toast.delivery"])
        XCTAssertEqual(HerdrConfigReset.setKeyPaths(in: doc, group: .tabs), ["keys.new_tab"])
        XCTAssertEqual(HerdrConfigReset.setKeyPaths(in: doc, group: .resize), [])
    }
}
