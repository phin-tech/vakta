//
//  HerdrKeyBindingsTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the herdr [keys] editor: chord grammar
//  (`prefix+shift+n`, `cmd+1..9`, `ctrl+alt+]`), the action catalog, conflict
//  detection, and per-row state/input rules. Pure. Plan phase 4.

import XCTest
@testable import Vakta

final class HerdrKeyBindingsTests: XCTestCase {
    private func action(_ name: String) throws -> HerdrKeyAction {
        try XCTUnwrap(HerdrKeyActionCatalog.action(named: name), "catalog is missing keys.\(name)")
    }

    // MARK: chord grammar

    func test_chord_parsesPrefixModifiersAndKey() throws {
        let chord = try HerdrKeyChord.parse("prefix+shift+n").get()
        XCTAssertTrue(chord.usesPrefix)
        XCTAssertEqual(chord.modifiers, [.shift])
        XCTAssertEqual(chord.key, "n")
    }

    func test_chord_directShortcutWithoutPrefix() throws {
        let chord = try HerdrKeyChord.parse("cmd+shift+]").get()
        XCTAssertFalse(chord.usesPrefix)
        XCTAssertEqual(chord.modifiers, [.shift, .cmd])
        XCTAssertEqual(chord.key, "]")
    }

    func test_chord_formatting_isCanonicalRegardlessOfInputOrderAndCase() throws {
        XCTAssertEqual(try HerdrKeyChord.parse("prefix+shift+ctrl+n").get().formatted, "prefix+ctrl+shift+n")
        XCTAssertEqual(try HerdrKeyChord.parse("cmd+alt+ctrl+left").get().formatted, "ctrl+alt+cmd+left")
    }

    func test_chord_acceptsRangesNamedPunctuationFunctionAndSpecialKeys() {
        for good in ["prefix+1..9", "cmd+1..9", "prefix+minus", "prefix+plus", "prefix+backtick", "cmd+`",
                     "prefix+?", "f12", "prefix+f5", "esc", "-", "up", "prefix+tab", "prefix+shift+tab",
                     "ctrl+alt+]", "prefix+alt+1..9", "prefix+comma"] {
            guard case .success = HerdrKeyChord.parse(good) else { return XCTFail("\(good) should parse") }
        }
    }

    func test_chord_rejectsMalformedInput() {
        for bad in ["prefix+", "+n", "prefix+prefix+n", "ctrl+", "hyper+n", "ctrl+banana", "n+ctrl", "prefix", "ctrl+shift",
                    "two words", "ctrl+nn"] {
            guard case .failure = HerdrKeyChord.parse(bad) else { return XCTFail("\(bad) should be rejected") }
        }
    }

    func test_chord_prefixMustComeFirst() {
        guard case .failure = HerdrKeyChord.parse("ctrl+prefix+n") else { return XCTFail("prefix must lead") }
    }

    // MARK: catalog

    func test_catalog_actionsAreUniqueAndPathsAreUnderKeys() {
        let names = HerdrKeyActionCatalog.actions.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertEqual(try action("new_tab").path, "keys.new_tab")
    }

    func test_catalog_documentedDefaults() throws {
        XCTAssertEqual(try action("prefix").defaultBinding, "ctrl+b")
        XCTAssertEqual(try action("split_horizontal").defaultBinding, "prefix+minus")
        XCTAssertEqual(try action("switch_tab").defaultBinding, "prefix+1..9")
        XCTAssertNil(try action("last_pane").defaultBinding)
        XCTAssertEqual(try action("navigate_pane_left").defaultBinding, "h")
    }

    func test_catalog_everyDefaultParsesUnderItsOwnRules() {
        for action in HerdrKeyActionCatalog.actions {
            guard let binding = action.defaultBinding else { continue }
            XCTAssertNil(HerdrKeyBindingRules.problem(for: binding, action: action), "\(action.name): \(binding)")
        }
    }

    func test_catalog_defaultsDoNotConflictWithEachOther() {
        let defaults = HerdrKeyActionCatalog.actions.compactMap { action in
            action.defaultBinding.map { (action.name, $0) }
        }
        XCTAssertEqual(HerdrKeyConflicts.find(in: defaults), [:])
    }

    // MARK: rules

    func test_rules_prefixKeyItselfCannotUseThePrefixOrBeEmpty() throws {
        let prefix = try action("prefix")
        XCTAssertNil(HerdrKeyBindingRules.problem(for: "ctrl+a", action: prefix))
        XCTAssertNotNil(HerdrKeyBindingRules.problem(for: "prefix+a", action: prefix))
        XCTAssertNotNil(HerdrKeyBindingRules.problem(for: "", action: prefix))
    }

    func test_rules_navigateModeKeysRejectPrefixEscEnterTabAndRanges() throws {
        let left = try action("navigate_pane_left")
        XCTAssertNil(HerdrKeyBindingRules.problem(for: "a", action: left))
        for bad in ["prefix+h", "esc", "enter", "tab", "1..9"] {
            XCTAssertNotNil(HerdrKeyBindingRules.problem(for: bad, action: left), bad)
        }
    }

    func test_rules_emptyBinding_onlyForActionsUnsetByDefault() throws {
        XCTAssertNil(HerdrKeyBindingRules.problem(for: "", action: try action("last_pane")))
        XCTAssertNotNil(HerdrKeyBindingRules.problem(for: "", action: try action("new_tab")))
    }

    // MARK: conflicts

    func test_conflicts_groupActionsSharingTheSameNormalizedChord() {
        let found = HerdrKeyConflicts.find(in: [
            ("a", "prefix+shift+ctrl+n"), ("b", "prefix+ctrl+shift+n"), ("c", "prefix+n"), ("d", "ctrl+n")
        ])
        XCTAssertEqual(found, ["prefix+ctrl+shift+n": ["a", "b"]])
    }

    func test_conflicts_ignoreUnparseableAndEmptyBindings() {
        XCTAssertEqual(HerdrKeyConflicts.find(in: [("a", ""), ("b", ""), ("c", "???+"), ("d", "???+")]), [:])
    }

    // MARK: row state

    func test_bindingState_absentShowsDefault_setInFileShowsFileValue() throws {
        let doc = HerdrConfigDocument(text: "[keys]\nnew_tab = \"cmd+t\"\n")
        let unset = HerdrKeyBindingState.resolve(try action("close_tab"), in: doc)
        XCTAssertEqual(unset.binding, "prefix+shift+x")
        XCTAssertFalse(unset.isSetInFile)
        let set = HerdrKeyBindingState.resolve(try action("new_tab"), in: doc)
        XCTAssertEqual(set.binding, "cmd+t")
        XCTAssertTrue(set.isSetInFile)
        XCTAssertNil(set.problem)
    }

    func test_bindingState_arrayValue_isReadOnlyAndKeptVerbatim() throws {
        let doc = HerdrConfigDocument(text: "[keys]\nnext_tab = [\"prefix+n\", \"ctrl+alt+]\"]\n")
        let state = HerdrKeyBindingState.resolve(try action("next_tab"), in: doc)
        XCTAssertFalse(state.isEditable)
        XCTAssertEqual(state.rawText, "[\"prefix+n\", \"ctrl+alt+]\"]")
    }

    func test_bindingState_invalidStringInFile_staysEditableWithProblem() throws {
        let doc = HerdrConfigDocument(text: "[keys]\nnew_tab = \"cmd+banana\"\n")
        let state = HerdrKeyBindingState.resolve(try action("new_tab"), in: doc)
        XCTAssertTrue(state.isEditable)
        XCTAssertNotNil(state.problem)
    }

    func test_bindingState_rangeValueLikeRealFile_isValid() throws {
        let doc = HerdrConfigDocument(text: "[keys]\nswitch_workspace = \"cmd+1..9\"\nlast_pane = \"cmd+`\"\n")
        XCTAssertNil(HerdrKeyBindingState.resolve(try action("switch_workspace"), in: doc).problem)
        XCTAssertNil(HerdrKeyBindingState.resolve(try action("last_pane"), in: doc).problem)
    }

    // MARK: input

    func test_input_trimsAndValidates_keepingTheUsersSpelling() throws {
        let new = try action("new_tab")
        XCTAssertEqual(HerdrKeyBindingInput.value(from: "  prefix+shift+ctrl+c ", for: new),
                       .success(.string("prefix+shift+ctrl+c")))
        guard case .failure = HerdrKeyBindingInput.value(from: "cmd+banana", for: new) else { return XCTFail() }
        guard case .failure = HerdrKeyBindingInput.value(from: "", for: new) else { return XCTFail() }
        XCTAssertEqual(HerdrKeyBindingInput.value(from: "", for: try action("last_pane")), .success(.string("")))
    }
}
