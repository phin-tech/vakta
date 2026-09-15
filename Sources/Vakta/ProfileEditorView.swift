//
//  ProfileEditorView.swift
//  Vakta
//
//  A modal (sheet) for creating or editing a `Profile`: name, command,
//  working directory, environment, and lifecycle. Presented from
//  `SidebarView`'s "New Session" menu ("New Profile…" / "Edit Profile…").
//
//  The view edits a working copy and only reports it back on Save, so Cancel
//  discards cleanly. Environment maps (`[String: String]`) and the scrub list
//  (`[String]`) are edited as line-oriented text and parsed on the way out.

import SwiftUI

struct ProfileEditorView: View {
    /// Working copy; committed only on Save.
    @State private var draft: Profile
    /// `KEY=VALUE` per line, one line per `environment` entry.
    @State private var environmentText: String
    /// One variable name per line for `scrubbedEnvironmentKeys`.
    @State private var scrubText: String

    let isNew: Bool
    let onSave: (Profile) -> Void
    let onCancel: () -> Void
    /// Present only when editing an existing profile.
    let onDelete: (() -> Void)?

    init(
        profile: Profile,
        isNew: Bool,
        onSave: @escaping (Profile) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: profile)
        _environmentText = State(
            initialValue: profile.environment
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
        )
        _scrubText = State(initialValue: profile.scrubbedEnvironmentKeys.joined(separator: "\n"))
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Profile" : "Edit Profile")
                .font(.headline)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Command", text: $draft.command)
                        .font(.system(.body, design: .monospaced))
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Arguments", text: $draft.arguments)
                            .font(.system(.body, design: .monospaced))
                        Text("`{name}` is replaced with the session name, e.g. "
                            + "`--session {name}` or `--remote me@host --session {name}`.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "Working Directory",
                        text: Binding(
                            get: { draft.workingDirectory ?? "" },
                            set: { draft.workingDirectory = $0.isEmpty ? nil : $0 }
                        ),
                        prompt: Text("Inherit")
                    )
                    .font(.system(.body, design: .monospaced))
                }

                Section("Environment") {
                    LabeledField(label: "Set (KEY=VALUE per line)") {
                        TextEditor(text: $environmentText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 54)
                    }
                    LabeledField(label: "Clear (one name per line)") {
                        TextEditor(text: $scrubText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 54)
                    }
                }

                Section {
                    Toggle("Keep terminal open after the command exits", isOn: Binding(
                        get: { draft.waitAfterCommand ?? false },
                        set: { draft.waitAfterCommand = $0 ? true : nil }
                    ))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(committedProfile()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 440)
    }

    /// Folds the text-edited environment/scrub fields back into the draft.
    private func committedProfile() -> Profile {
        var profile = draft
        profile.name = draft.name.trimmingCharacters(in: .whitespaces)
        profile.command = draft.command.trimmingCharacters(in: .whitespaces)
        profile.environment = Self.parseEnvironment(environmentText)
        profile.scrubbedEnvironmentKeys = Self.parseLines(scrubText)
        return profile
    }

    /// `KEY=VALUE` lines → dictionary. Blank lines and lines without `=` are
    /// skipped; the value may itself contain `=`.
    static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = String(line[line.index(after: eq)...])
        }
        return result
    }

    /// Non-empty, trimmed lines.
    static func parseLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// A stacked label + control, since a multi-line `TextEditor` reads badly on
/// `Form`'s default trailing-control row.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
        }
    }
}
