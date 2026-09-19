//
//  HerdrConfigView.swift
//  Vakta
//
//  The "Herdr Config" preferences pane: a GUI over herdr's own config.toml
//  (the file is the source of truth -- see `HerdrConfigStore`). Two tabs:
//  structured Settings generated from `HerdrConfigCatalog`, and a Raw editor
//  for everything the catalog doesn't cover. Edits stay in memory until Save,
//  which validates with `herdr config check` first.

import AppKit
import SwiftUI

struct HerdrConfigView: View {
    @EnvironmentObject private var store: HerdrConfigStore
    @State private var tab: Tab = .settings
    @State private var message: HerdrConfigSaveMessage?
    @State private var canSaveUnverified = false
    @State private var isSaving = false

    private enum Tab: String, CaseIterable, Identifiable {
        case settings = "Settings"
        case keys = "Keys"
        case raw = "Raw"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .settings: settingsForm
            case .keys: keysForm
            case .raw: rawEditor
            }
            Divider()
            footer
        }
        .onAppear { if !store.isDirty { store.load() } }
    }

    private var header: some View {
        HStack {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            Spacer()
            Text(store.filePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
        }
        .padding(10)
    }

    private var settingsForm: some View {
        Form {
            if let error = store.loadError {
                Text("Couldn't read config.toml: \(error)").foregroundStyle(.red)
            }
            ForEach(HerdrConfigCatalog.groups, id: \.self) { group in
                Section(group.title) {
                    ForEach(HerdrConfigCatalog.entries(in: group), id: \.path) { entry in
                        HerdrConfigFieldRow(entry: entry)
                    }
                }
            }
            let unmanaged = store.document.keyPaths(excluding: Set(HerdrConfigCatalog.entries.map(\.path)))
            if !unmanaged.isEmpty {
                Section {
                    ForEach(unmanaged, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                } header: {
                    Text("Not managed by this editor")
                } footer: {
                    Text("Present in your file and preserved as-is. Edit them in the Raw tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var keysForm: some View {
        let conflicts = HerdrKeyConflicts.find(in: store.document)
        return Form {
            Section {
                EmptyView()
            } footer: {
                Text("Bindings use herdr's syntax: prefix+shift+n, cmd+1..9, ctrl+alt+]. "
                    + "“prefix+” means after the prefix key. Leave a row at its default to keep herdr's binding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(HerdrKeyGroup.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(HerdrKeyActionCatalog.actions(in: group), id: \.name) { action in
                        HerdrKeyBindingRow(action: action, conflicts: conflicts)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var rawEditor: some View {
        TextEditor(text: Binding(get: { store.document.text }, set: { store.replaceText($0) }))
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
    }

    private var footer: some View {
        HStack {
            if let message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                    .lineLimit(3)
            }
            Spacer()
            if canSaveUnverified {
                Button("Save anyway") { save(confirmUnverified: true) }
            }
            Button("Revert") {
                store.load()
                message = nil
                canSaveUnverified = false
            }
            .disabled(!store.isDirty)
            Button("Save") { save(confirmUnverified: false) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.isDirty || isSaving)
        }
        .padding(10)
    }

    private func save(confirmUnverified: Bool) {
        isSaving = true
        Task {
            let result = await store.save(confirmUnverified: confirmUnverified)
            message = HerdrConfigSaveMessage.describe(result)
            canSaveUnverified = result == .needsUnverifiedConfirmation
            isSaving = false
        }
    }
}

/// One catalog entry as a form row. Text-like fields keep a local draft and
/// commit on Return so a half-typed number never becomes a document edit.
private struct HerdrConfigFieldRow: View {
    let entry: HerdrConfigCatalog.Entry
    @EnvironmentObject private var store: HerdrConfigStore
    @State private var draft = ""
    @State private var inputError: String?

    var body: some View {
        let state = HerdrConfigFieldState.resolve(entry, in: store.document)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.label)
                if entry.requiresRestart {
                    Text("restart").font(.caption2).padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                if state.isSetInFile {
                    Circle().fill(.tint).frame(width: 6, height: 6).help("Set in config.toml")
                }
                Spacer()
                control(state)
                if state.isSetInFile {
                    Button {
                        store.unset(entry.path)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from config.toml (use herdr's default)")
                }
            }
            Text(inputError ?? state.problem ?? entry.help)
                .font(.caption)
                .foregroundStyle(inputError != nil || state.problem != nil ? Color.red : Color.secondary)
        }
    }

    @ViewBuilder
    private func control(_ state: HerdrConfigFieldState) -> some View {
        if !state.isEditable {
            Text(state.rawText ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        } else {
            switch entry.kind {
            case .bool:
                Toggle("", isOn: Binding(
                    get: { state.value == .bool(true) },
                    set: { store.set(entry.path, to: .bool($0)) }
                ))
                .labelsHidden()
            case .choice(let options):
                let current: String = { if case .string(let text) = state.value { return text } else { return "" } }()
                Picker("", selection: Binding(
                    get: { current },
                    set: { store.set(entry.path, to: .string($0)) }
                )) {
                    ForEach(options + (options.contains(current) ? [] : [current]), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            case .integer, .text, .color:
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(entry.kind.isNumeric ? .trailing : .leading)
                    .frame(width: entry.kind.isNumeric ? 90 : 220)
                    .onAppear { draft = display(state.value) }
                    .onChange(of: state.value) { draft = display($0) }
                    .onSubmit { commit() }
            }
        }
    }

    private func display(_ value: HerdrConfigValue) -> String {
        switch value {
        case .string(let text): return text
        case .integer(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .raw(let text): return text
        }
    }

    private func commit() {
        switch HerdrConfigInput.value(from: draft, for: entry) {
        case .success(let value):
            inputError = nil
            store.set(entry.path, to: value)
        case .failure(let error):
            inputError = error.message
        }
    }
}

private extension HerdrConfigCatalog.Kind {
    var isNumeric: Bool {
        if case .integer = self { return true }
        return false
    }
}


/// One `[keys]` action as a form row: a text field in herdr's chord syntax,
/// committed on Return, with live conflict and validity messages.
private struct HerdrKeyBindingRow: View {
    let action: HerdrKeyAction
    let conflicts: [String: [String]]
    @EnvironmentObject private var store: HerdrConfigStore
    @State private var draft = ""
    @State private var inputError: String?

    var body: some View {
        let state = HerdrKeyBindingState.resolve(action, in: store.document)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(action.label)
                if state.isSetInFile {
                    Circle().fill(.tint).frame(width: 6, height: 6).help("Set in config.toml")
                }
                Spacer()
                if state.isEditable {
                    TextField(action.defaultBinding ?? "unbound", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 200)
                        .onAppear { draft = state.binding }
                        .onChange(of: state.binding) { draft = $0 }
                        .onSubmit { commit() }
                } else {
                    Text(state.rawText ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if state.isSetInFile {
                    Button {
                        store.unset(action.path)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from config.toml (use herdr's default)")
                }
            }
            if let message = inputError ?? state.problem ?? conflictMessage(state) ?? readOnlyNote(state) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == readOnlyNote(state) ? Color.secondary : Color.red)
            }
        }
    }

    private func conflictMessage(_ state: HerdrKeyBindingState) -> String? {
        guard case .success(let chord) = HerdrKeyChord.parse(state.binding),
              let sharing = conflicts[chord.formatted], sharing.contains(action.name) else { return nil }
        let others = sharing.filter { $0 != action.name }
            .map { HerdrKeyActionCatalog.action(named: $0)?.label ?? $0 }
        return "Also bound to: \(others.joined(separator: ", "))"
    }

    private func readOnlyNote(_ state: HerdrKeyBindingState) -> String? {
        state.isEditable ? nil : "Multiple bindings — edit in the Raw tab."
    }

    private func commit() {
        switch HerdrKeyBindingInput.value(from: draft, for: action) {
        case .success(let value):
            inputError = nil
            // Committing the default text unchanged shouldn't pin it into the file.
            if case .string(let text) = value, text == (action.defaultBinding ?? ""),
               !HerdrKeyBindingState.resolve(action, in: store.document).isSetInFile { return }
            store.set(action.path, to: value)
        case .failure(let error):
            inputError = error.message
        }
    }
}
