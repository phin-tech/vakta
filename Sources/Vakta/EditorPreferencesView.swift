//
//  EditorPreferencesView.swift
//  Vakta
//
//  The "Editor" preferences pane: which editor "Open in Editor" launches.
//  Applies immediately via `EditorPreferencesStore`.

import SwiftUI

struct EditorPreferencesView: View {
    @EnvironmentObject private var editorPreferences: EditorPreferencesStore

    private var installedEditors: Set<EditorChoice> {
        EditorLaunchAdapter.installedEditors()
    }

    var body: some View {
        Form {
            Section {
                Picker("Editor", selection: $editorPreferences.choice) {
                    ForEach(EditorChoice.allCases) { choice in
                        Text(label(for: choice)).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func label(for choice: EditorChoice) -> String {
        guard choice != .auto else { return choice.title }
        return installedEditors.contains(choice) ? choice.title : "\(choice.title) (not installed)"
    }

    /// Only names the step-3 fallback -- the marker/`$EDITOR` steps depend
    /// on whichever session is focused when "Open in Editor" runs, which
    /// this pane can't predict.
    private var footer: String {
        if let fallback = OpenInEditorPlanner.autoFallback(installedEditors: installedEditors) {
            return "Finds the focused pane's directory (herdr or tmux) and opens it in the chosen editor. "
                + "“Automatic” prefers a project's own editor when it can tell, otherwise falls back to \(fallback.title)."
        }
        return "Finds the focused pane's directory (herdr or tmux) and opens it in the chosen editor. "
            + "“Automatic” currently has no installed editor to fall back to."
    }
}
