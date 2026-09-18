//
//  OpenInEditorPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `OpenInEditorPlanner.plan`: which editor
//  actually launches for a resolved working directory, given the user's
//  `EditorChoice` preference. Pure over snapshots -- `installedEditors`
//  (from `NSWorkspace.urlForApplication(withBundleIdentifier:)`),
//  `directoryEntries` (a `contentsOfDirectory` listing), and
//  `editorEnvironmentCommand` (`$VISUAL`/`$EDITOR`'s bare command name) are
//  all supplied by the shell -- no I/O in this file.
//
//  `.auto` resolution order (this plan's "smart" detection):
//    1. a project marker in `directoryEntries`, if that editor is installed
//    2. `editorEnvironmentCommand`, if that editor is installed
//    3. the first installed editor in a fixed preference list
//  A marker or `$EDITOR` naming an editor that ISN'T installed must fall
//  through to the next step, not fail outright.
//
//  RED: `OpenInEditorPlanner`/`OpenInEditorOutcome` do not exist yet -- this
//  file will not compile until they're declared.

import XCTest
@testable import Vakta

final class OpenInEditorPlannerTests: XCTestCase {
    private func plan(
        choice: EditorChoice = .auto,
        installedEditors: Set<EditorChoice> = [],
        workingDirectory: String? = "/Users/sam/src/vakta",
        directoryExists: Bool = true,
        directoryEntries: [String] = [],
        editorEnvironmentCommand: String? = nil
    ) -> OpenInEditorOutcome {
        OpenInEditorPlanner.plan(
            choice: choice,
            installedEditors: installedEditors,
            workingDirectory: workingDirectory,
            directoryExists: directoryExists,
            directoryEntries: directoryEntries,
            editorEnvironmentCommand: editorEnvironmentCommand
        )
    }

    // MARK: failure precedence -- checked before any editor resolution

    func test_noWorkingDirectory_isReportedRegardlessOfInstalledEditors() {
        XCTAssertEqual(
            plan(choice: .vscode, installedEditors: [.vscode], workingDirectory: nil),
            .noWorkingDirectory
        )
    }

    func test_workingDirectoryDoesNotExist_isReportedBeforeEditorResolution() {
        XCTAssertEqual(
            plan(choice: .vscode, installedEditors: [.vscode], directoryExists: false),
            .directoryMissing
        )
    }

    // MARK: explicit (non-auto) choice

    func test_explicitChoice_installed_opensThatEditor() {
        XCTAssertEqual(
            plan(choice: .zed, installedEditors: [.vscode, .zed]),
            .open(editor: .zed, directory: "/Users/sam/src/vakta")
        )
    }

    func test_explicitChoice_notInstalled_reportsNoEditorInstalled() {
        // Guards against a stale/wrong bundle ID (e.g. Cursor's, marked "to
        // verify" in the plan) crashing rather than degrading gracefully.
        XCTAssertEqual(
            plan(choice: .cursor, installedEditors: [.vscode]),
            .noEditorInstalled
        )
    }

    // MARK: auto -- step 1, project markers

    func test_auto_xcodeprojMarker_choosesXcodeWhenInstalled() {
        XCTAssertEqual(
            plan(choice: .auto, installedEditors: [.vscode, .xcode], directoryEntries: ["Vakta.xcodeproj", "README.md"]),
            .open(editor: .xcode, directory: "/Users/sam/src/vakta")
        )
    }

    func test_auto_codeWorkspaceMarker_choosesVSCodeWhenInstalled() {
        XCTAssertEqual(
            plan(choice: .auto, installedEditors: [.vscode, .xcode], directoryEntries: ["project.code-workspace"]),
            .open(editor: .vscode, directory: "/Users/sam/src/vakta")
        )
    }

    func test_auto_markerNamesUninstalledEditor_fallsThroughToNextStep() {
        // Xcode isn't installed, but $EDITOR names an installed one -- the
        // marker must not force `.noEditorInstalled`.
        XCTAssertEqual(
            plan(
                choice: .auto,
                installedEditors: [.zed],
                directoryEntries: ["Vakta.xcodeproj"],
                editorEnvironmentCommand: "zed"
            ),
            .open(editor: .zed, directory: "/Users/sam/src/vakta")
        )
    }

    // MARK: auto -- step 2, $EDITOR/$VISUAL

    func test_auto_environmentCommand_choosesMatchingInstalledEditor() {
        XCTAssertEqual(
            plan(choice: .auto, installedEditors: [.vscode, .sublimeText], editorEnvironmentCommand: "subl"),
            .open(editor: .sublimeText, directory: "/Users/sam/src/vakta")
        )
    }

    func test_auto_environmentCommandNamesUninstalledEditor_fallsThroughToFixedList() {
        XCTAssertEqual(
            plan(choice: .auto, installedEditors: [.zed], editorEnvironmentCommand: "code"),
            .open(editor: .zed, directory: "/Users/sam/src/vakta")
        )
    }

    func test_auto_environmentCommandUnrecognized_fallsThroughToFixedList() {
        // e.g. $EDITOR=vim -- not one of the GUI editors this feature
        // targets; falls straight to the fixed-list step.
        XCTAssertEqual(
            plan(choice: .auto, installedEditors: [.zed], editorEnvironmentCommand: "vim"),
            .open(editor: .zed, directory: "/Users/sam/src/vakta")
        )
    }

    // MARK: auto -- step 3, fixed preference list

    func test_auto_noMarkerNoEnvironment_choosesFirstInstalledInFixedOrder() {
        XCTAssertEqual(
            plan(choice: .auto, installedEditors: [.bbedit, .vscode]),
            .open(editor: .vscode, directory: "/Users/sam/src/vakta")
        )
    }

    func test_auto_noEditorsInstalled_reportsNoEditorInstalled() {
        XCTAssertEqual(plan(choice: .auto, installedEditors: []), .noEditorInstalled)
    }

    // MARK: auto -- step ordering

    func test_auto_markerWinsOverEnvironmentCommand() {
        XCTAssertEqual(
            plan(
                choice: .auto,
                installedEditors: [.vscode, .xcode],
                directoryEntries: ["Vakta.xcodeproj"],
                editorEnvironmentCommand: "code"
            ),
            .open(editor: .xcode, directory: "/Users/sam/src/vakta")
        )
    }
}
