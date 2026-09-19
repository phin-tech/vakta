//
//  HerdrConfigDocumentTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `HerdrConfigDocument` (surgical text patching of
//  herdr's config.toml) and `HerdrConfigSavePlanner`. Pure input/output: no
//  files, no `herdr` process. See docs/herdr-config-gui-plan.md.

import XCTest
@testable import Vakta

final class HerdrConfigDocumentTests: XCTestCase {
    /// Shape of a real hand-written config (comments, sparse [keys], a range
    /// value, a user-added key). Inlined so tests never read user files.
    private let realisticFile = """
    onboarding = false
    # Keep Herdr's default Ctrl+B prefix. No custom plugin command bindings.
    [keys]
    new_tab = "cmd+t"
    switch_workspace = "cmd+1..9"
    last_pane = "cmd+`"

    [ui]
    agent_panel_sort = "priority"
    status_indicators = "symbols"
    """

    // MARK: reading

    func test_value_readsStringBoolIntegerAndDottedTablePaths() {
        let doc = HerdrConfigDocument(text: """
        onboarding = false
        [ui]
        mouse_scroll_lines = 5
        tab_bar_position = "bottom"
        [ui.toast]
        delivery = "system"
        """)
        XCTAssertEqual(doc.value(at: "onboarding"), .bool(false))
        XCTAssertEqual(doc.value(at: "ui.mouse_scroll_lines"), .integer(5))
        XCTAssertEqual(doc.value(at: "ui.tab_bar_position"), .string("bottom"))
        XCTAssertEqual(doc.value(at: "ui.toast.delivery"), .string("system"))
    }

    func test_value_dottedKeyUnderParentTable_resolvesToFullPath() {
        let doc = HerdrConfigDocument(text: "[ui]\ntoast.delivery = \"herdr\"\n")
        XCTAssertEqual(doc.value(at: "ui.toast.delivery"), .string("herdr"))
    }

    func test_value_absentOrCommentedOutKey_isNil() {
        let doc = HerdrConfigDocument(text: "[ui]\n# tab_bar_position = \"bottom\"\n")
        XCTAssertNil(doc.value(at: "ui.tab_bar_position"))
        XCTAssertNil(doc.value(at: "terminal.shell_mode"))
    }

    func test_value_stringContainingHashOrEquals_isNotTruncated() {
        let doc = HerdrConfigDocument(text: "[ui]\nwindow_title = \"{workspace} # a=b\"\n")
        XCTAssertEqual(doc.value(at: "ui.window_title"), .string("{workspace} # a=b"))
    }

    // MARK: setting an existing key

    func test_setting_existingKey_changesOnlyThatValueSpan() {
        let doc = HerdrConfigDocument(text: realisticFile)
        let updated = doc.setting("keys.new_tab", to: .string("cmd+shift+t"))
        XCTAssertEqual(
            updated.text,
            realisticFile.replacingOccurrences(of: "new_tab = \"cmd+t\"", with: "new_tab = \"cmd+shift+t\"")
        )
    }

    func test_setting_keepsTrailingInlineComment() {
        let doc = HerdrConfigDocument(text: "[ui]\nconfirm_close = true # ask first\n")
        XCTAssertEqual(
            doc.setting("ui.confirm_close", to: .bool(false)).text,
            "[ui]\nconfirm_close = false # ask first\n"
        )
    }

    func test_setting_toCurrentValue_isByteIdentical() {
        let doc = HerdrConfigDocument(text: realisticFile)
        XCTAssertEqual(doc.setting("ui.status_indicators", to: .string("symbols")).text, realisticFile)
    }

    func test_setting_preservesCRLFLineEndings() {
        let doc = HerdrConfigDocument(text: "[ui]\r\nconfirm_close = true\r\nmouse_scroll_lines = 3\r\n")
        XCTAssertEqual(
            doc.setting("ui.confirm_close", to: .bool(false)).text,
            "[ui]\r\nconfirm_close = false\r\nmouse_scroll_lines = 3\r\n"
        )
    }

    func test_setting_stringWithQuoteOrBackslash_isEscaped() {
        let doc = HerdrConfigDocument(text: "[ui]\nwindow_title = \"x\"\n")
        let updated = doc.setting("ui.window_title", to: .string("say \"hi\" \\ there"))
        XCTAssertEqual(updated.text, "[ui]\nwindow_title = \"say \\\"hi\\\" \\\\ there\"\n")
        XCTAssertEqual(updated.value(at: "ui.window_title"), .string("say \"hi\" \\ there"))
    }

    func test_setting_existingRangeValue_isPreservedWhenUntouched() {
        let doc = HerdrConfigDocument(text: realisticFile)
        let updated = doc.setting("ui.agent_panel_sort", to: .string("spaces"))
        XCTAssertEqual(updated.value(at: "keys.switch_workspace"), .string("cmd+1..9"))
    }

    // MARK: inserting a new key

    func test_setting_missingKeyInExistingTable_insertsAtEndOfThatTable() {
        let doc = HerdrConfigDocument(text: "[ui]\na = 1\n\n[keys]\nnew_tab = \"cmd+t\"\n")
        XCTAssertEqual(
            doc.setting("ui.confirm_close", to: .bool(false)).text,
            "[ui]\na = 1\nconfirm_close = false\n\n[keys]\nnew_tab = \"cmd+t\"\n"
        )
    }

    func test_setting_missingTable_createsItAtEndOfFile() {
        let doc = HerdrConfigDocument(text: "[ui]\na = 1\n")
        XCTAssertEqual(
            doc.setting("terminal.shell_mode", to: .string("login")).text,
            "[ui]\na = 1\n\n[terminal]\nshell_mode = \"login\"\n"
        )
    }

    func test_setting_missingTopLevelKey_isInsertedBeforeFirstTableHeader() {
        let doc = HerdrConfigDocument(text: "[keys]\nnew_tab = \"cmd+t\"\n")
        XCTAssertEqual(
            doc.setting("onboarding", to: .bool(false)).text,
            "onboarding = false\n[keys]\nnew_tab = \"cmd+t\"\n"
        )
    }

    func test_setting_nestedKeyWhenExactTableHeaderExists_usesThatTableNotADottedKey() {
        let doc = HerdrConfigDocument(text: "[ui]\na = 1\n\n[ui.toast]\ndelay_seconds = 2\n")
        let updated = doc.setting("ui.toast.delivery", to: .string("system"))
        XCTAssertEqual(updated.text, "[ui]\na = 1\n\n[ui.toast]\ndelay_seconds = 2\ndelivery = \"system\"\n")
    }

    func test_setting_emptyDocument_createsTableAndKey() {
        XCTAssertEqual(
            HerdrConfigDocument(text: "").setting("ui.confirm_close", to: .bool(false)).text,
            "[ui]\nconfirm_close = false\n"
        )
    }

    func test_setting_insertIntoTableAtEndOfFileWithoutTrailingNewline_addsSeparatorNewline() {
        let doc = HerdrConfigDocument(text: "[ui]\na = 1")
        XCTAssertEqual(doc.setting("ui.b", to: .integer(2)).text, "[ui]\na = 1\nb = 2\n")
    }

    // MARK: unsetting

    func test_unsetting_removesOnlyThatLine() {
        let doc = HerdrConfigDocument(text: realisticFile)
        XCTAssertEqual(
            doc.unsetting("ui.status_indicators").text,
            realisticFile.replacingOccurrences(of: "\nstatus_indicators = \"symbols\"", with: "")
        )
    }

    func test_unsetting_lastKeyInTable_keepsTheHeaderAndComments() {
        let doc = HerdrConfigDocument(text: "# top\n[ui]\n# note\nconfirm_close = false\n")
        XCTAssertEqual(doc.unsetting("ui.confirm_close").text, "# top\n[ui]\n# note\n")
    }

    func test_unsetting_absentKey_isByteIdentical() {
        let doc = HerdrConfigDocument(text: realisticFile)
        XCTAssertEqual(doc.unsetting("terminal.shell_mode").text, realisticFile)
    }

    // MARK: things the editor does not own

    func test_setting_leavesCommandArrayTablesAndUnknownKeysUntouched() {
        let text = """
        [keys]
        new_tab = "cmd+t"
        mystery_future_key = { a = 1, b = [2, 3] }

        [[keys.command]]
        key = "prefix+alt+g"
        type = "popup"
        command = "lazygit"
        """
        let updated = HerdrConfigDocument(text: text).setting("keys.new_tab", to: .string("cmd+n"))
        XCTAssertEqual(updated.text, text.replacingOccurrences(of: "\"cmd+t\"", with: "\"cmd+n\""))
    }

    func test_value_multilineArray_isReportedRawAndNotEditable() {
        let doc = HerdrConfigDocument(text: "[ui.sidebar.agents]\nrows = [\n  [\"agent\"],\n  [\"tab\"],\n]\n")
        guard case .raw? = doc.value(at: "ui.sidebar.agents.rows") else {
            return XCTFail("multi-line arrays must surface as .raw, got \(String(describing: doc.value(at: "ui.sidebar.agents.rows")))")
        }
    }

    func test_setting_afterMultilineArrayValue_doesNotSplitTheArray() {
        let doc = HerdrConfigDocument(text: "[ui.sidebar.agents]\nrows = [\n  [\"agent\"],\n]\n")
        XCTAssertEqual(
            doc.setting("ui.sidebar.agents.row_gap", to: .integer(1)).text,
            "[ui.sidebar.agents]\nrows = [\n  [\"agent\"],\n]\nrow_gap = 1\n"
        )
    }

    func test_unmanagedKeys_listsKeysAbsentFromTheKnownSet() {
        let doc = HerdrConfigDocument(text: "[ui]\nconfirm_close = true\nfuture_thing = 1\n")
        XCTAssertEqual(doc.keyPaths(excluding: ["ui.confirm_close"]), ["ui.future_thing"])
    }

    // MARK: save planner

    func test_savePlanner_savesWhenFileUnchangedAndCheckPasses() {
        XCTAssertEqual(
            HerdrConfigSavePlanner.decide(
                baseFingerprint: "a", currentFingerprint: "a", check: .valid),
            .save
        )
    }

    func test_savePlanner_rejectsInvalidCandidateBeforeAnythingElse() {
        let diagnostic = HerdrConfigDiagnostic(line: 2, column: 20, message: "unknown variant `sideways`")
        XCTAssertEqual(
            HerdrConfigSavePlanner.decide(
                baseFingerprint: "a", currentFingerprint: "b", check: .invalid([diagnostic])),
            .rejectInvalid([diagnostic])
        )
    }

    func test_savePlanner_reportsConflictWhenFileChangedSinceLoad() {
        XCTAssertEqual(
            HerdrConfigSavePlanner.decide(
                baseFingerprint: "a", currentFingerprint: "b", check: .valid),
            .conflictExternalEdit
        )
    }

    func test_savePlanner_missingHerdrBinary_requiresExplicitUnverifiedConfirmation() {
        XCTAssertEqual(
            HerdrConfigSavePlanner.decide(
                baseFingerprint: "a", currentFingerprint: "a", check: .unavailable),
            .needsUnverifiedConfirmation
        )
    }

    // MARK: check-output parsing

    func test_diagnostics_parsesLineColumnAndMessageFromHerdrCheckOutput() {
        let output = """
        config: issues found
        config parse error: TOML parse error at line 2, column 20
          |
        2 | tab_bar_position = "sideways"
          |                    ^^^^^^^^^^
        unknown variant `sideways`, expected `top` or `bottom`
        ; using defaults
        """
        XCTAssertEqual(
            HerdrConfigDiagnostic.parse(checkOutput: output),
            [HerdrConfigDiagnostic(line: 2, column: 20, message: "unknown variant `sideways`, expected `top` or `bottom`")]
        )
    }

    func test_diagnostics_semanticProblemsWithoutPosition_becomeOneUnpositionedDiagnosticPerLine() {
        // Real output for a config where two actions share a binding.
        let output = "config: issues found\nshift+cmd+t: kept keys.new_tab, disabled keys.rename_tab\n"
        XCTAssertEqual(
            HerdrConfigDiagnostic.parse(checkOutput: output),
            [HerdrConfigDiagnostic(line: 0, column: 0, message: "shift+cmd+t: kept keys.new_tab, disabled keys.rename_tab")]
        )
    }

    func test_diagnostics_okOutputYieldsNone() {
        XCTAssertEqual(HerdrConfigDiagnostic.parse(checkOutput: "config: ok\n"), [])
    }
}
