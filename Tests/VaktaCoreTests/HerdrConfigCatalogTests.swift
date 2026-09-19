//
//  HerdrConfigCatalogTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the herdr config editor's field layer: the key
//  catalog, per-field validation, text-input parsing, effective-value
//  resolution against a document, and save-result messaging. Pure.
//  See docs/herdr-config-gui-plan.md, phase 3.

import XCTest
@testable import Vakta

final class HerdrConfigCatalogTests: XCTestCase {
    private func entry(_ path: String) throws -> HerdrConfigCatalog.Entry {
        try XCTUnwrap(HerdrConfigCatalog.entry(for: path), "catalog is missing \(path)")
    }

    // MARK: catalog invariants

    func test_catalog_pathsAreUnique() {
        let paths = HerdrConfigCatalog.entries.map(\.path)
        XCTAssertEqual(paths.count, Set(paths).count)
    }

    func test_catalog_everyDefaultIsValidForItsOwnKind() {
        for entry in HerdrConfigCatalog.entries {
            XCTAssertNil(
                HerdrConfigFieldValidator.validate(entry.defaultValue, for: entry),
                "\(entry.path) default \(entry.defaultValue) fails its own validator"
            )
        }
    }

    func test_catalog_documentedKeysAndDefaultsFromTheReference() throws {
        XCTAssertEqual(try entry("terminal.shell_mode").defaultValue, .string("auto"))
        XCTAssertEqual(try entry("ui.tab_bar_position").kind, .choice(["top", "bottom"]))
        XCTAssertEqual(try entry("ui.mouse_scroll_lines").defaultValue, .integer(3))
        XCTAssertEqual(try entry("session.resume_agents_on_restore").defaultValue, .bool(true))
        // config-reference and `herdr --default-config` say "off"; the
        // configuration page says "herdr" -- catalog follows the former.
        XCTAssertEqual(try entry("ui.toast.delivery").defaultValue, .string("off"))
    }

    func test_catalog_onlyDocumentedRestartKeyIsFlaggedRestart() {
        XCTAssertEqual(HerdrConfigCatalog.entries.filter(\.requiresRestart).map(\.path), ["ui.sidebar_start_collapsed"])
    }

    func test_catalog_groupsAreNonEmptyAndOrderedForDisplay() {
        let groups = HerdrConfigCatalog.groups
        XCTAssertFalse(groups.isEmpty)
        XCTAssertEqual(groups.first, .terminal)
        for group in groups { XCTAssertFalse(HerdrConfigCatalog.entries(in: group).isEmpty) }
    }

    func test_catalog_unknownPathIsNil() {
        XCTAssertNil(HerdrConfigCatalog.entry(for: "ui.not_a_thing"))
    }

    // MARK: validation

    func test_validate_integerRange_isEnforcedAtBothEnds() throws {
        let delay = try entry("ui.toast.delay_seconds") // 0...3600
        XCTAssertNil(HerdrConfigFieldValidator.validate(.integer(0), for: delay))
        XCTAssertNil(HerdrConfigFieldValidator.validate(.integer(3600), for: delay))
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.integer(-1), for: delay))
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.integer(3601), for: delay))
        let cols = try entry("server.headless_cols") // must be > 0
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.integer(0), for: cols))
    }

    func test_validate_choice_rejectsValuesOutsideTheSet() throws {
        let position = try entry("ui.tab_bar_position")
        XCTAssertNil(HerdrConfigFieldValidator.validate(.string("bottom"), for: position))
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.string("sideways"), for: position))
    }

    func test_validate_typeMismatch_isRejected() throws {
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.string("yes"), for: try entry("ui.confirm_close")))
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.bool(true), for: try entry("ui.tab_bar_position")))
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.raw("[1]"), for: try entry("ui.confirm_close")))
    }

    func test_validate_color_acceptsHexRgbNamedAndReset_rejectsGarbage() throws {
        let accent = try entry("ui.accent")
        for good in ["#fff", "#89b4fa", "rgb(137,180,250)", "rgb( 1, 2, 3 )", "cyan", "reset"] {
            XCTAssertNil(HerdrConfigFieldValidator.validate(.string(good), for: accent), good)
        }
        for bad in ["#ggg", "#12345", "rgb(1,2)", "rgb(300,0,0)", "", "two words"] {
            XCTAssertNotNil(HerdrConfigFieldValidator.validate(.string(bad), for: accent), bad)
        }
    }

    // MARK: text input

    func test_input_integerText_parsesTrimsAndRejectsNonNumbers() throws {
        let scroll = try entry("ui.mouse_scroll_lines")
        XCTAssertEqual(HerdrConfigInput.value(from: " 7 ", for: scroll), .success(.integer(7)))
        guard case .failure = HerdrConfigInput.value(from: "seven", for: scroll) else { return XCTFail() }
        guard case .failure = HerdrConfigInput.value(from: "", for: scroll) else { return XCTFail() }
        guard case .failure = HerdrConfigInput.value(from: "0", for: try entry("server.headless_rows")) else {
            return XCTFail("range failure must surface from input parsing")
        }
    }

    func test_input_textAndColor_passThroughValidation() throws {
        XCTAssertEqual(
            HerdrConfigInput.value(from: "{workspace}", for: try entry("ui.window_title")),
            .success(.string("{workspace}"))
        )
        XCTAssertEqual(
            HerdrConfigInput.value(from: "#89b4fa", for: try entry("ui.accent")),
            .success(.string("#89b4fa"))
        )
        guard case .failure = HerdrConfigInput.value(from: "#zzz", for: try entry("ui.accent")) else { return XCTFail() }
    }

    // MARK: field state

    func test_fieldState_absentKey_showsDefaultAndIsNotSetInFile() throws {
        let state = HerdrConfigFieldState.resolve(try entry("ui.confirm_close"), in: HerdrConfigDocument(text: ""))
        XCTAssertEqual(state.value, .bool(true))
        XCTAssertFalse(state.isSetInFile)
        XCTAssertTrue(state.isEditable)
    }

    func test_fieldState_presentKey_showsFileValue_evenWhenEqualToDefault() throws {
        let doc = HerdrConfigDocument(text: "[ui]\nconfirm_close = true\nmouse_scroll_lines = 9\n")
        XCTAssertTrue(HerdrConfigFieldState.resolve(try entry("ui.confirm_close"), in: doc).isSetInFile)
        let scroll = HerdrConfigFieldState.resolve(try entry("ui.mouse_scroll_lines"), in: doc)
        XCTAssertEqual(scroll.value, .integer(9))
        XCTAssertTrue(scroll.isSetInFile)
    }

    func test_fieldState_valueOfWrongTypeInFile_isReadOnlyWithRawText() throws {
        let doc = HerdrConfigDocument(text: "[ui]\nconfirm_close = \"maybe\"\nmouse_scroll_lines = [1, 2]\n")
        let bool = HerdrConfigFieldState.resolve(try entry("ui.confirm_close"), in: doc)
        XCTAssertFalse(bool.isEditable)
        XCTAssertEqual(bool.rawText, "\"maybe\"")
        XCTAssertFalse(HerdrConfigFieldState.resolve(try entry("ui.mouse_scroll_lines"), in: doc).isEditable)
    }

    func test_fieldState_outOfSetChoiceInFile_staysEditableSoItCanBeCorrected() throws {
        let doc = HerdrConfigDocument(text: "[ui]\ntab_bar_position = \"sideways\"\n")
        let state = HerdrConfigFieldState.resolve(try entry("ui.tab_bar_position"), in: doc)
        XCTAssertTrue(state.isEditable)
        XCTAssertEqual(state.value, .string("sideways"))
        XCTAssertNotNil(state.problem)
    }

    // MARK: theme color layers

    func test_catalog_themeColorTokens_existForBaseLightAndDarkLayers() throws {
        for prefix in ["theme.custom", "theme.custom.light", "theme.custom.dark"] {
            for token in ["accent", "panel_bg", "sidebar_bg", "active_row_bg", "selection_bg", "surface0", "surface1",
                          "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow",
                          "red", "blue", "teal", "peach"] {
                let entry = try entry("\(prefix).\(token)")
                XCTAssertEqual(entry.kind, .color)
            }
        }
    }

    func test_validate_optionalColor_acceptsEmptyMeaningUnset_butDefaultedColorDoesNot() throws {
        XCTAssertNil(HerdrConfigFieldValidator.validate(.string(""), for: try entry("theme.custom.sidebar_bg")))
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.string(""), for: try entry("ui.accent")))
    }

    func test_input_emptyOptionalColor_isSuccessEmptyString_sotheRowCanUnset() throws {
        XCTAssertEqual(HerdrConfigInput.value(from: "  ", for: try entry("theme.custom.text")), .success(.string("")))
    }

    func test_fieldState_themeColorInLightLayer_readsDottedTablePath() throws {
        let doc = HerdrConfigDocument(text: "[theme.custom.light]\npanel_bg = \"#eff1f5\"\n")
        let state = HerdrConfigFieldState.resolve(try entry("theme.custom.light.panel_bg"), in: doc)
        XCTAssertEqual(state.value, .string("#eff1f5"))
        XCTAssertTrue(state.isSetInFile)
    }

    // MARK: save messaging

    func test_saveMessage_coversEveryResult() {
        let diagnostic = HerdrConfigDiagnostic(line: 2, column: 20, message: "unknown variant `sideways`")
        XCTAssertEqual(
            HerdrConfigSaveMessage.describe(.saved(reload: .reloaded)),
            HerdrConfigSaveMessage(text: "Saved and reloaded herdr.", isError: false)
        )
        let failedReload = HerdrConfigSaveMessage.describe(.saved(reload: .failed("exited with status 3")))
        XCTAssertFalse(failedReload.isError)
        XCTAssertTrue(failedReload.text.contains("Saved"))
        XCTAssertTrue(failedReload.text.contains("exited with status 3"))
        let rejected = HerdrConfigSaveMessage.describe(.rejectedInvalid([diagnostic]))
        XCTAssertTrue(rejected.isError)
        XCTAssertTrue(rejected.text.contains("line 2"))
        XCTAssertTrue(rejected.text.contains("unknown variant `sideways`"))
        XCTAssertTrue(HerdrConfigSaveMessage.describe(.conflictExternalEdit).isError)
        XCTAssertTrue(HerdrConfigSaveMessage.describe(.needsUnverifiedConfirmation).isError)
        XCTAssertTrue(HerdrConfigSaveMessage.describe(.writeFailed("permission denied")).text.contains("permission denied"))
    }
}

final class HerdrConfigSuggestedValueTests: XCTestCase {
    private func entry(_ path: String) throws -> HerdrConfigCatalog.Entry {
        try XCTUnwrap(HerdrConfigCatalog.entry(for: path), "catalog is missing \(path)")
    }

    func test_themeNames_areSuggestedFromTheBuiltIns_andStillAcceptAnyString() throws {
        let theme = try entry("theme.name")
        guard case .suggested(let options) = theme.kind else { return XCTFail("theme.name should offer suggestions") }
        XCTAssertTrue(options.contains("dracula") && options.contains("tokyo-night") && options.contains("catppuccin"))
        XCTAssertNil(HerdrConfigFieldValidator.validate(.string("my-custom-theme"), for: theme))
        XCTAssertNotNil(HerdrConfigFieldValidator.validate(.bool(true), for: theme))
    }

    func test_optionalThemeNames_offerNotSetAsTheEmptyOption() throws {
        for path in ["theme.dark_name", "theme.light_name"] {
            guard case .suggested(let options) = try entry(path).kind else { return XCTFail(path) }
            XCTAssertEqual(options.first, "")
        }
    }

    func test_newPaneDirectory_suggestsTheDocumentedPolicies_butAllowsAFixedPath() throws {
        let cwd = try entry("terminal.new_cwd")
        guard case .suggested(let options) = cwd.kind else { return XCTFail() }
        XCTAssertEqual(options, ["follow", "home", "current"])
        XCTAssertNil(HerdrConfigFieldValidator.validate(.string("~/Projects"), for: cwd))
    }

    func test_perAgentSounds_areDefaultOnOffChoices_withDroidMutedByDefault() throws {
        XCTAssertEqual(try entry("ui.sound.agents.claude").kind, .choice(["default", "on", "off"]))
        XCTAssertEqual(try entry("ui.sound.agents.claude").defaultValue, .string("default"))
        XCTAssertEqual(try entry("ui.sound.agents.droid").defaultValue, .string("off"))
        XCTAssertEqual(HerdrConfigCatalog.entries.filter { $0.path.hasPrefix("ui.sound.agents.") }.count, 22)
    }

    func test_cjkCursorShape_isAChoice() throws {
        XCTAssertEqual(
            try entry("experimental.cjk_ime_cursor_shape").kind,
            .choice(["block", "steady_block", "underline", "steady_underline", "bar", "steady_bar"])
        )
    }

    func test_suggestedInput_isTrimmedString_andEmptyIsAllowedForOptionalOnes() throws {
        XCTAssertEqual(HerdrConfigInput.value(from: " dracula ", for: try entry("theme.name")), .success(.string("dracula")))
        XCTAssertEqual(HerdrConfigInput.value(from: "", for: try entry("theme.dark_name")), .success(.string("")))
    }

    func test_fieldState_suggestedValueOfWrongShape_isReadOnly() throws {
        let doc = HerdrConfigDocument(text: "[theme]\nname = 5\n")
        XCTAssertFalse(HerdrConfigFieldState.resolve(try entry("theme.name"), in: doc).isEditable)
    }
}

final class HerdrConfigManagedPathsTests: XCTestCase {
    func test_managedPaths_coverSettingsKeyBindingsAndSidebarRows() {
        let managed = HerdrConfigCatalog.editorManagedPaths
        XCTAssertTrue(managed.contains("ui.tab_bar_position"))
        XCTAssertTrue(managed.contains("keys.new_tab"), "edited on the Keys tab")
        XCTAssertTrue(managed.contains("ui.sidebar.agents.rows"), "edited on the Sidebar rows tab")
        XCTAssertFalse(managed.contains("ui.tab_bar_right"))
        XCTAssertFalse(managed.contains("ui.sidebar.agents.rows_by_agent"))
    }

    func test_unmanagedList_showsOnlyKeysNoTabEdits() {
        let doc = HerdrConfigDocument(text: "[keys]\nnew_tab = \"cmd+t\"\n[ui]\ntab_bar_right = [\"zoom\"]\nfuture_key = 1\n")
        XCTAssertEqual(doc.keyPaths(excluding: HerdrConfigCatalog.editorManagedPaths), ["ui.tab_bar_right", "ui.future_key"])
    }
}
