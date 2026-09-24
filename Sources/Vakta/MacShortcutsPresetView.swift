//
//  MacShortcutsPresetView.swift
//  Vakta
//
//  The Mac-style shortcut preset's chord table, what applying it would
//  displace, and Apply / Revert -- shared by Preferences ▸ Keybindings and
//  the welcome tour. State lives in `KeybindingMatcher`; this is a projection.
//

import SwiftUI

struct MacShortcutsPresetView: View {
    @ObservedObject var matcher: KeybindingMatcher

    /// The last Apply's config backup, shown under the buttons.
    @State private var backupNote: String?
    @State private var backupFolder: URL?

    var body: some View {
        let preset = KeybindingPreset.macStyle
        let applied = matcher.isMacStylePresetApplied
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(Array(preset.summaryRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.chords)
                            .font(.system(.body, design: .monospaced))
                        Text(row.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !applied {
                let changes = preset.changeDescriptions(from: matcher.bindings)
                if !changes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Applying also changes:")
                            .font(.caption.weight(.semibold))
                        ForEach(changes, id: \.self) { line in
                            Text("• " + line).font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                if applied {
                    Label("Mac-style shortcuts are on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Revert") { matcher.revertMacStylePreset() }
                } else {
                    Button("Use Mac-style Shortcuts", action: apply)
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                }
            }

            if let backupNote {
                HStack(alignment: .firstTextBaseline) {
                    Text(backupNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let backupFolder {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([backupFolder])
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// Copies the tmux/herdr configs first; if that fails, nothing changes.
    private func apply() {
        switch MultiplexerConfigBackup.backUpForMacShortcuts(root: matcher.storageRoot) {
        case .backedUp(let folder, let files):
            backupFolder = folder
            backupNote = "Saved a copy of your config first (\(files.joined(separator: ", ")))."
            matcher.applyMacStylePreset()
        case .nothingToBackUp:
            backupFolder = nil
            backupNote = nil
            matcher.applyMacStylePreset()
        case .failed(let reason):
            backupFolder = nil
            backupNote = "Couldn't copy your tmux/herdr config, so nothing was changed: \(reason)"
        }
    }
}
