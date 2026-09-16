//
//  KeybindingsPreferencesView.swift
//  Vakta
//
//  The "Keybindings" preferences pane: one row per bindable action, showing
//  its current chord and letting the user record a new one, clear it, or reset
//  everything to defaults. Edits apply immediately (the macOS preferences
//  convention) -- `KeybindingMatcher.bindings.didSet` persists each change, so
//  there is no Save/Cancel here.
//
//  Recording routes through the matcher's own event monitor (`captureNext`)
//  rather than a second local monitor, which the matcher's earlier-installed
//  monitor would shadow (settled design decision #6 -- it runs in front of
//  everything).

import AppKit
import SwiftUI

struct KeybindingsPreferencesView: View {
    @EnvironmentObject private var matcher: KeybindingMatcher

    /// The action currently being recorded, if any.
    @State private var recordingAction: KeybindingAction?
    /// A transient hint shown under the list (e.g. "needs a modifier").
    @State private var notice: String?

    /// The fixed, ordered set of bindable actions the pane exposes. Session
    /// selection covers the nine default chords; the two app actions ship
    /// unbound and can be assigned here.
    private static let sessionActions: [KeybindingAction] = (0..<9).map { .selectSession($0) }
    private static let appActions: [KeybindingAction] = [.openSessionSwitcher, .toggleSidebar, .openPreferences, .quit]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Application") {
                    ForEach(Self.appActions, id: \.self) { action in
                        row(for: action)
                    }
                }
                Section("Sessions") {
                    ForEach(Self.sessionActions, id: \.self) { action in
                        row(for: action)
                    }
                }

                Section {
                    Picker("Passthrough", selection: $matcher.passthroughToggle) {
                        ForEach(PassthroughToggle.allCases) { toggle in
                            Text(toggle.title).tag(toggle)
                        }
                    }
                } header: {
                    Text("Passthrough Mode")
                } footer: {
                    Text("Double-tap this modifier to send every key straight to the "
                        + "focused session — no Vakta shortcuts intercept. Double-tap "
                        + "again to return. The menu-bar item shows when it's active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if recordingAction != nil {
                    Text("Press a chord, or ⎋ to cancel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to Defaults") {
                    cancelRecording()
                    matcher.resetToDefaults()
                    notice = nil
                }
            }
            .padding(16)
        }
        .onDisappear { cancelRecording() }
    }

    @ViewBuilder
    private func row(for action: KeybindingAction) -> some View {
        let isRecording = recordingAction == action
        HStack {
            Text(action.title)
            Spacer()
            if let binding = matcher.binding(for: action), !isRecording {
                Text(binding.displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    matcher.clearBinding(for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear this shortcut")
            }
            Button(isRecording ? "Recording…" : "Record") {
                isRecording ? cancelRecording() : startRecording(action)
            }
            .fixedSize()
        }
    }

    private func startRecording(_ action: KeybindingAction) {
        recordingAction = action
        notice = nil
        let recording = $recordingAction
        let noticeBinding = $notice
        matcher.captureNext = { event in
            recording.wrappedValue = nil
            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            // ⎋ with no modifiers cancels the recording.
            if event.keyCode == 53, mods.isEmpty { return }
            // A bare key would silently swallow that key in every terminal
            // surface, so require at least one modifier.
            guard !mods.isEmpty else {
                noticeBinding.wrappedValue = "A shortcut needs at least one modifier (⌃ ⌥ ⇧ ⌘)."
                return
            }
            matcher.setBinding(mods, keyCode: event.keyCode, for: action)
            noticeBinding.wrappedValue = nil
        }
    }

    private func cancelRecording() {
        matcher.captureNext = nil
        recordingAction = nil
    }
}
