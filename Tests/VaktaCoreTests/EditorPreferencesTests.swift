//
//  EditorPreferencesTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `EditorPreferences`/`EditorChoice`: which editor
//  "Open in Editor" launches, `.auto` by default. Mirrors
//  `HerdrPreferencesTests`'s decode-missing-field shape -- an old
//  `editor.json` predating this feature (i.e. one that doesn't exist yet)
//  still decodes.
//
//  RED: `EditorChoice`/`EditorPreferences` do not exist yet. This file will
//  not compile until they're declared (see AGENTS.md: a compilation failure
//  here is expected harness-missing state, not evidence the behavior itself
//  is wrong).

import XCTest
@testable import Vakta

final class EditorPreferencesTests: XCTestCase {
    func test_default_choiceIsAuto() {
        XCTAssertEqual(EditorPreferences().choice, .auto)
    }

    func test_decode_missingField_defaultsToAuto() throws {
        let decoded = try JSONDecoder().decode(EditorPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.choice, .auto)
    }

    func test_decode_explicitChoice_isHonored() throws {
        let decoded = try JSONDecoder().decode(EditorPreferences.self, from: Data(#"{"choice":"vscode"}"#.utf8))
        XCTAssertEqual(decoded.choice, .vscode)
    }

    func test_roundTrip_preservesValue() throws {
        let original = EditorPreferences(choice: .zed)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditorPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: EditorChoice

    func test_allCases_areCovered() {
        // Locks the set this plan committed to; JetBrains IDEs are explicitly
        // out of scope (per-product bundle IDs, separate effort).
        XCTAssertEqual(
            Set(EditorChoice.allCases),
            [.auto, .vscode, .cursor, .xcode, .zed, .sublimeText, .bbedit, .nova, .textmate]
        )
    }

    func test_auto_hasNoBundleIdentifier() {
        XCTAssertNil(EditorChoice.auto.bundleIdentifier)
    }

    func test_namedEditors_haveBundleIdentifiers() {
        // VS Code / Xcode / Zed verified live on this machine
        // (`mdls -name kMDItemCFBundleIdentifier`); the rest are declared
        // but flagged "to verify" in the plan -- a wrong ID must resolve to
        // "not installed," never crash, which is exercised in
        // `OpenInEditorPlannerTests`, not here.
        XCTAssertEqual(EditorChoice.vscode.bundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(EditorChoice.xcode.bundleIdentifier, "com.apple.dt.Xcode")
        XCTAssertEqual(EditorChoice.zed.bundleIdentifier, "dev.zed.Zed")
        XCTAssertNotNil(EditorChoice.cursor.bundleIdentifier)
        XCTAssertNotNil(EditorChoice.sublimeText.bundleIdentifier)
        XCTAssertNotNil(EditorChoice.bbedit.bundleIdentifier)
        XCTAssertNotNil(EditorChoice.nova.bundleIdentifier)
        XCTAssertNotNil(EditorChoice.textmate.bundleIdentifier)
    }

    func test_commandName_mapsKnownEditorCommands() {
        // Used to interpret `$EDITOR`/`$VISUAL` in `OpenInEditorPlanner`'s
        // auto resolution -- a bare command name, not a full path.
        XCTAssertEqual(EditorChoice(commandName: "code"), .vscode)
        XCTAssertEqual(EditorChoice(commandName: "cursor"), .cursor)
        XCTAssertEqual(EditorChoice(commandName: "zed"), .zed)
        XCTAssertEqual(EditorChoice(commandName: "subl"), .sublimeText)
        XCTAssertEqual(EditorChoice(commandName: "bbedit"), .bbedit)
        XCTAssertNil(EditorChoice(commandName: "vim"))
    }
}
