//
//  OpenInEditorPlanner.swift
//  Vakta
//
//  Which editor "Open in Editor" actually launches. Pure over snapshots --
//  `installedEditors` (from `NSWorkspace.urlForApplication(withBundleIdentifier:)`),
//  `directoryEntries` (a `contentsOfDirectory` listing), and
//  `editorEnvironmentCommand` (`$VISUAL`/`$EDITOR`'s bare command name) are
//  all supplied by the caller; no I/O here.
//
//  `.auto` resolution order -- a marker or `$EDITOR` naming an editor that
//  isn't installed falls through to the next step rather than failing:
//    1. a project marker in `directoryEntries`
//    2. `editorEnvironmentCommand`
//    3. the first installed editor in a fixed preference list

import Foundation

enum OpenInEditorOutcome: Equatable {
    case open(editor: EditorChoice, directory: String)
    case noEditorInstalled
    case noWorkingDirectory
    case directoryMissing
}

enum OpenInEditorPlanner {
    /// RED-phase fixture for review, not a settled fact -- `Package.swift`
    /// implying Xcode is opinionated (many SwiftPM users are on Zed/VS Code).
    private static let markerRules: [(suffix: String, editor: EditorChoice)] = [
        (".xcodeproj", .xcode),
        (".xcworkspace", .xcode),
        (".code-workspace", .vscode),
    ]

    private static let fixedPreferenceOrder: [EditorChoice] = [.vscode, .cursor, .xcode, .zed, .sublimeText, .bbedit, .nova, .textmate]

    static func plan(
        choice: EditorChoice,
        installedEditors: Set<EditorChoice>,
        workingDirectory: String?,
        directoryExists: Bool,
        directoryEntries: [String],
        editorEnvironmentCommand: String?
    ) -> OpenInEditorOutcome {
        guard let workingDirectory else { return .noWorkingDirectory }
        guard directoryExists else { return .directoryMissing }

        if choice != .auto {
            guard installedEditors.contains(choice) else { return .noEditorInstalled }
            return .open(editor: choice, directory: workingDirectory)
        }

        if let markerEditor = markerEditor(in: directoryEntries), installedEditors.contains(markerEditor) {
            return .open(editor: markerEditor, directory: workingDirectory)
        }
        if let editorEnvironmentCommand,
           let envEditor = EditorChoice(commandName: editorEnvironmentCommand),
           installedEditors.contains(envEditor) {
            return .open(editor: envEditor, directory: workingDirectory)
        }
        if let firstInstalled = autoFallback(installedEditors: installedEditors) {
            return .open(editor: firstInstalled, directory: workingDirectory)
        }
        return .noEditorInstalled
    }

    /// `.auto`'s step-3 fallback (first installed editor in the fixed
    /// preference order), exposed for the Preferences pane to show what
    /// "Automatic" currently resolves to when no marker/`$EDITOR` applies --
    /// the only step Preferences can predict without a focused session's
    /// working directory.
    static func autoFallback(installedEditors: Set<EditorChoice>) -> EditorChoice? {
        fixedPreferenceOrder.first(where: installedEditors.contains)
    }

    private static func markerEditor(in entries: [String]) -> EditorChoice? {
        for entry in entries {
            if let rule = markerRules.first(where: { entry.hasSuffix($0.suffix) }) {
                return rule.editor
            }
        }
        return nil
    }
}
