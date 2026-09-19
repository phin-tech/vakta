//
//  HerdrCustomCommandTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `[[keys.command]]` editing: array-of-tables
//  patching in `HerdrConfigDocument` and the `HerdrCustomCommand` field
//  rules. Pure. Plan phase 6.

import XCTest
@testable import Vakta

final class HerdrCustomCommandTests: XCTestCase {
    private let path = "keys.command"

    private let twoBlocks = """
    [keys]
    new_tab = "cmd+t"

    [[keys.command]]
    key = "prefix+alt+g"
    type = "popup"
    command = "lazygit"

    [[keys.command]]
    key = "prefix+alt+t"
    type = "shell"
    command = "make test"
    """ + "\n"

    // MARK: reading

    func test_arrayTableEntries_readsBlocksInFileOrder() {
        let entries = HerdrConfigDocument(text: twoBlocks).arrayTableEntries(path)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].fields["command"], .string("lazygit"))
        XCTAssertEqual(entries[1].fields["type"], .string("shell"))
        XCTAssertEqual(entries[1].fields["key"], .string("prefix+alt+t"))
    }

    func test_arrayTableEntries_noneWhenAbsent() {
        XCTAssertEqual(HerdrConfigDocument(text: "[keys]\na = 1\n").arrayTableEntries(path), [])
    }

    // MARK: appending

    func test_append_toExistingFile_addsBlankSeparatorAndBlock() {
        let doc = HerdrConfigDocument(text: "[keys]\nnew_tab = \"cmd+t\"\n")
        XCTAssertEqual(
            doc.appendingArrayTable(path, fields: [("key", .string("prefix+g")), ("type", .string("popup")), ("command", .string("lazygit"))]).text,
            "[keys]\nnew_tab = \"cmd+t\"\n\n[[keys.command]]\nkey = \"prefix+g\"\ntype = \"popup\"\ncommand = \"lazygit\"\n"
        )
    }

    func test_append_toEmptyDocument_hasNoLeadingBlank() {
        XCTAssertEqual(
            HerdrConfigDocument(text: "").appendingArrayTable(path, fields: [("key", .string("a"))]).text,
            "[[keys.command]]\nkey = \"a\"\n"
        )
    }

    func test_append_afterUnterminatedLastLine_addsNewlineFirst() {
        XCTAssertEqual(
            HerdrConfigDocument(text: "a = 1").appendingArrayTable(path, fields: [("key", .string("k"))]).text,
            "a = 1\n\n[[keys.command]]\nkey = \"k\"\n"
        )
    }

    // MARK: removing

    func test_remove_firstBlock_keepsRestAndCollapsesTheDoubledBlank() {
        XCTAssertEqual(
            HerdrConfigDocument(text: twoBlocks).removingArrayTable(path, at: 0).text,
            "[keys]\nnew_tab = \"cmd+t\"\n\n[[keys.command]]\nkey = \"prefix+alt+t\"\ntype = \"shell\"\ncommand = \"make test\"\n"
        )
    }

    func test_remove_lastBlock_dropsItAndItsSeparatorBlank() {
        XCTAssertEqual(
            HerdrConfigDocument(text: twoBlocks).removingArrayTable(path, at: 1).text,
            "[keys]\nnew_tab = \"cmd+t\"\n\n[[keys.command]]\nkey = \"prefix+alt+g\"\ntype = \"popup\"\ncommand = \"lazygit\"\n"
        )
    }

    func test_remove_outOfRangeIndex_isNoOp() {
        XCTAssertEqual(HerdrConfigDocument(text: twoBlocks).removingArrayTable(path, at: 5).text, twoBlocks)
    }

    func test_remove_onlyBlock_leavesTheRestOfTheFile() {
        let text = "[keys]\na = 1\n\n[[keys.command]]\nkey = \"x\"\n"
        XCTAssertEqual(HerdrConfigDocument(text: text).removingArrayTable(path, at: 0).text, "[keys]\na = 1\n")
    }

    // MARK: editing fields

    func test_setField_existing_changesOnlyThatBlocksValue() {
        let updated = HerdrConfigDocument(text: twoBlocks).settingInArrayTable(path, at: 1, key: "command", to: .string("make"))
        XCTAssertEqual(updated.text, twoBlocks.replacingOccurrences(of: "make test", with: "make"))
    }

    func test_setField_missing_insertsAfterThatBlocksLastLine_notInTheNextBlock() {
        let updated = HerdrConfigDocument(text: twoBlocks).settingInArrayTable(path, at: 0, key: "width", to: .string("80%"))
        XCTAssertEqual(
            updated.text,
            twoBlocks.replacingOccurrences(of: "command = \"lazygit\"\n", with: "command = \"lazygit\"\nwidth = \"80%\"\n")
        )
        XCTAssertEqual(updated.arrayTableEntries(path)[0].fields["width"], .string("80%"))
        XCTAssertNil(updated.arrayTableEntries(path)[1].fields["width"])
    }

    func test_unsetField_removesOnlyThatLineInThatBlock() {
        let updated = HerdrConfigDocument(text: twoBlocks).unsettingInArrayTable(path, at: 0, key: "type")
        XCTAssertEqual(updated.text, twoBlocks.replacingOccurrences(of: "type = \"popup\"\n", with: ""))
    }

    func test_arrayTableFields_doNotLeakIntoRegularPathLookups() {
        XCTAssertNil(HerdrConfigDocument(text: twoBlocks).value(at: "keys.command.command"))
    }

    // MARK: command rules

    func test_command_fromEntry_andOrderedFieldPairs() {
        let entry = HerdrConfigDocument(text: twoBlocks).arrayTableEntries(path)[0]
        let command = HerdrCustomCommand(entry: entry)
        XCTAssertEqual(command.key, "prefix+alt+g")
        XCTAssertEqual(command.type, "popup")
        XCTAssertEqual(command.command, "lazygit")
        XCTAssertNil(command.problems.first)
        XCTAssertEqual(command.fieldPairs.map(\.0), ["key", "type", "command"])
    }

    func test_command_rules_keyTypeAndCommandAreValidated() {
        func problems(_ key: String, _ type: String, _ command: String, width: String = "", height: String = "") -> [String] {
            HerdrCustomCommand(key: key, type: type, command: command, description: "", width: width, height: height).problems
        }
        XCTAssertEqual(problems("prefix+g", "popup", "lazygit"), [])
        XCTAssertFalse(problems("", "popup", "lazygit").isEmpty)
        XCTAssertFalse(problems("prefix+banana", "popup", "lazygit").isEmpty)
        XCTAssertFalse(problems("prefix+g", "window", "lazygit").isEmpty)
        XCTAssertFalse(problems("prefix+g", "shell", "  ").isEmpty)
        XCTAssertEqual(problems("prefix+g", "popup", "lazygit", width: "80%", height: "24"), [])
        XCTAssertFalse(problems("prefix+g", "popup", "lazygit", width: "wide").isEmpty)
        XCTAssertFalse(problems("prefix+g", "popup", "lazygit", height: "-3").isEmpty)
    }

    func test_command_pluginAction_isNotEditableByTheForm() {
        let command = HerdrCustomCommand(
            key: "prefix+p", type: "plugin_action", command: "", description: "", width: "", height: "")
        XCTAssertFalse(command.isFormEditable)
        XCTAssertEqual(command.problems, [])
    }

    func test_command_fieldPairs_omitEmptyOptionalFieldsAndKeepDocumentedOrder() {
        let command = HerdrCustomCommand(
            key: "prefix+g", type: "popup", command: "lazygit", description: "run lazygit", width: "80%", height: "80%")
        XCTAssertEqual(command.fieldPairs.map(\.0), ["key", "type", "command", "description", "width", "height"])
    }
}
