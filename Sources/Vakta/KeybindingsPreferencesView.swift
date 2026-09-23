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
//  monitor would shadow (docs/architecture.md's "The matcher runs in front
//  of every surface" invariant).

import AppKit
import SwiftUI

struct KeybindingsPreferencesView: View {
    @EnvironmentObject private var matcher: KeybindingMatcher

    /// The action currently being recorded, if any.
    @State private var recordingAction: AppCommand?
    /// Whether the leader chord (rather than an action) is being recorded.
    @State private var isRecordingLeader = false
    /// A transient hint shown under the list (e.g. "needs a modifier").
    @State private var notice: String?

    /// The bindable commands, grouped by `AppCommandGroup` in catalog order.
    /// Derived from `AppCommandCatalog` so a command can't be dispatchable
    /// yet missing from Preferences.
    private static let sections: [(group: AppCommandGroup, commands: [AppCommand])] =
        AppCommandGroup.allCases.compactMap { group in
            let commands = AppCommandCatalog.bindableCommands.filter { $0.group == group }
            return commands.isEmpty ? nil : (group, commands)
        }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                ForEach(Self.sections, id: \.group) { section in
                    Section(section.group.title) {
                        ForEach(section.commands, id: \.self) { command in
                            row(for: command)
                        }
                    }
                }

                Section {
                    Toggle("Enable leader key", isOn: $matcher.leaderSettings.isEnabled)
                    HStack {
                        Text("Leader chord")
                        Spacer()
                        if !isRecordingLeader {
                            Text(matcher.leaderSettings.chordDisplayString)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button(isRecordingLeader ? "Recording…" : "Record") {
                            isRecordingLeader ? cancelRecording() : startRecordingLeader()
                        }
                        .fixedSize()
                    }
                    .disabled(!matcher.leaderSettings.isEnabled)
                    LabeledContent("Show key hints after") {
                        HStack {
                            Slider(value: leaderHintDelay, in: 0...1000, step: 50)
                                .frame(minWidth: 160)
                            Text(leaderHintDelayLabel)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 80, alignment: .trailing)
                        }
                    }
                    .disabled(!matcher.leaderSettings.isEnabled)
                } header: {
                    Text("Leader Key")
                } footer: {
                    Text("Spacemacs/Doom-style: press the leader chord, then the keys "
                        + "the overlay lists — e.g. \(matcher.leaderSettings.chordDisplayString) w v "
                        + "splits the pane right. ⎋ cancels, ⌫ goes back a level. "
                        + "A shortcut on the leader chord is unbound.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                } else if recordingAction != nil || isRecordingLeader {
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
        // The matcher can drop a capture for a reason other than this
        // view's own button/Escape/delivered-key paths -- namely
        // `cancelCaptureWhenResigningKey(from:)`, when the Preferences
        // window loses key status mid-recording. Without this, `Self`'s
        // `recordingAction` would stay set after the matcher has already
        // stopped capturing, so the row would keep showing "Recording…"
        // while the next keystroke anywhere quietly matches normally
        // instead of being recorded.
        .onChange(of: matcher.isCapturing) { isCapturing in
            if !isCapturing {
                recordingAction = nil
                isRecordingLeader = false
            }
        }
    }

    /// The slider edits whole milliseconds; the matcher persists each change.
    private var leaderHintDelay: Binding<Double> {
        Binding(
            get: { Double(matcher.leaderSettings.hintDelayMilliseconds) },
            set: { matcher.leaderSettings.hintDelayMilliseconds = Int($0.rounded()) }
        )
    }

    private var leaderHintDelayLabel: String {
        let milliseconds = matcher.leaderSettings.clampedHintDelayMilliseconds
        return milliseconds == 0 ? "Instantly" : "\(milliseconds) ms"
    }

    @ViewBuilder
    private func row(for action: AppCommand) -> some View {
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

    private func startRecording(_ action: AppCommand) {
        recordingAction = action
        let recording = $recordingAction
        capture(onEnd: { recording.wrappedValue = nil }) { mods, keyCode in
            matcher.setBinding(mods, keyCode: keyCode, for: action)
        }
    }

    private func startRecordingLeader() {
        recordingAction = nil
        isRecordingLeader = true
        let recording = $isRecordingLeader
        capture(onEnd: { recording.wrappedValue = false }) { mods, keyCode in
            matcher.setLeaderChord(mods, keyCode: keyCode)
        }
    }

    /// Claims the next key through the matcher's monitor. ⎋ cancels; a chord
    /// with no modifier is refused (it would swallow that key in every
    /// terminal); otherwise `apply` stores it.
    private func capture(
        onEnd: @escaping () -> Void,
        apply: @escaping (NSEvent.ModifierFlags, UInt16) -> Void
    ) {
        notice = nil
        let noticeBinding = $notice
        matcher.captureNext = { event in
            onEnd()
            let mods = event.modifierFlags.intersection(SessionSwitcherKeyRouter.relevantModifierMask)
            // ⎋ with no modifiers cancels the recording.
            if event.keyCode == 53, mods.isEmpty { return }
            // A bare key would silently swallow that key in every terminal
            // surface, so require at least one modifier.
            guard !mods.isEmpty else {
                noticeBinding.wrappedValue = "A shortcut needs at least one modifier (⌃ ⌥ ⇧ ⌘)."
                return
            }
            // `setBinding`/`setLeaderChord` normalize this same mask again --
            // the intersection here is only to decide "does this chord have
            // a modifier at all," not to build the stored mask by hand.
            apply(mods, event.keyCode)
            noticeBinding.wrappedValue = nil
        }
    }

    private func cancelRecording() {
        matcher.captureNext = nil
        recordingAction = nil
        isRecordingLeader = false
    }
}
