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
    @State private var query = ""
    /// `query` after a short pause -- searching rebuilds many Form rows, so it
    /// shouldn't run on every keystroke.
    @State private var appliedQuery = ""
    @State private var settingsGroup: HerdrConfigGroup = .terminal
    @State private var keyGroup: HerdrKeyGroup = .general
    @State private var message: HerdrConfigSaveMessage?
    @State private var canSaveUnverified = false
    @State private var isSaving = false

    private enum Tab: String, CaseIterable, Identifiable {
        case settings = "Settings"
        case keys = "Keys"
        case commands = "Commands"
        case sidebar = "Sidebar rows"
        case raw = "Raw"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if HerdrConfigSearch.isActive(appliedQuery) {
                searchResults.id(store.loadGeneration)
            } else {
                tabContent.id(store.loadGeneration)
            }
            Divider()
            footer
        }
        .onAppear { store.reloadIfChangedOnDisk() }
        .task(id: query) {
            if query.isEmpty { appliedQuery = ""; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled { appliedQuery = query }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        VStack(spacing: 0) {
            switch tab {
            case .settings: settingsForm
            case .keys: keysForm
            case .commands: commandsForm
            case .sidebar: sidebarForm
            case .raw: rawEditor
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(HerdrConfigSearch.isActive(appliedQuery))
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings and keys", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text(store.filePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 200)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
            }
        }
        .padding(10)
    }

    private var searchResults: some View {
        let allSettings = HerdrConfigSearch.settings(matching: appliedQuery)
        let allActions = HerdrConfigSearch.keyActions(matching: appliedQuery, in: store.document)
        // Each row is a live AppKit-backed control set; cap what is built.
        let cap = 30
        let settings = Array(allSettings.prefix(cap))
        let actions = Array(allActions.prefix(max(0, cap - settings.count)))
        let hidden = allSettings.count + allActions.count - settings.count - actions.count
        let conflicts = HerdrKeyConflicts.find(in: store.document)
        return Form {
            if settings.isEmpty, actions.isEmpty {
                Text("No settings or key bindings match “\(appliedQuery)”.").foregroundStyle(.secondary)
            }
            if !settings.isEmpty {
                Section("Settings") {
                    ForEach(settings, id: \.path) { HerdrConfigFieldRow(entry: $0) }
                }
            }
            if !actions.isEmpty {
                Section("Keys") {
                    ForEach(actions, id: \.name) { HerdrKeyBindingRow(action: $0, conflicts: conflicts) }
                }
            }
            if hidden > 0 {
                Text("\(hidden) more — refine your search to see them.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var settingsForm: some View {
        Form {
            if let error = store.loadError {
                Text("Couldn't read config.toml: \(error)").foregroundStyle(.red)
            }
            Section {
                Picker("Section", selection: $settingsGroup) {
                    ForEach(HerdrConfigCatalog.groups, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                ForEach(HerdrConfigCatalog.entries(in: settingsGroup), id: \.path) { entry in
                    HerdrConfigFieldRow(entry: entry)
                }
            } header: {
                HStack {
                    Text(settingsGroup.title)
                    Spacer()
                    Button("Reset Section") {
                        store.apply { HerdrConfigReset.settings(in: $0, group: settingsGroup) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(HerdrConfigReset.setSettingPaths(in: store.document, group: settingsGroup).isEmpty)
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
                    + "“prefix+” means after the prefix key. Clear a field and press Return to reset it to herdr's default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Section", selection: $keyGroup) {
                    ForEach(HerdrKeyGroup.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                ForEach(HerdrKeyActionCatalog.actions(in: keyGroup), id: \.name) { action in
                    HerdrKeyBindingRow(action: action, conflicts: conflicts)
                }
            } header: {
                HStack {
                    Text(keyGroup.title)
                    Spacer()
                    Button("Reset Section") {
                        store.apply { HerdrConfigReset.keys(in: $0, group: keyGroup) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(HerdrConfigReset.setKeyPaths(in: store.document, group: keyGroup).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var commandsForm: some View {
        let commands = store.document.arrayTableEntries(HerdrCustomCommand.tablePath)
            .map(HerdrCustomCommand.init(entry:))
        return Form {
            Section {
                ForEach(commands.indices, id: \.self) { index in
                    HerdrCommandRow(index: index, command: commands[index])
                }
                Button {
                    store.apply {
                        $0.appendingArrayTable(HerdrCustomCommand.tablePath, fields: [
                            ("key", .string("prefix+alt+x")), ("type", .string("popup")), ("command", .string("")),
                        ])
                    }
                } label: {
                    Label("Add command", systemImage: "plus")
                }
            } header: {
                Text("Custom commands")
            } footer: {
                Text("Bind a key to run a command in a popup, a temporary pane, or the background (shell). "
                    + "A new command needs a real key and command before herdr will accept the file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var sidebarForm: some View {
        Form {
            HerdrSidebarRowsSection(kind: .agents, title: "Agent rows")
            HerdrSidebarRowsSection(kind: .spaces, title: "Space rows")
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
            Button("Discard Changes") {
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
    @FocusState private var focused: Bool

    var body: some View {
        let state = HerdrConfigFieldState.resolve(entry, in: store.document)
        LabeledContent {
            HStack(spacing: 6) {
                control(state)
                Button {
                    store.unset(entry.path)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!state.isSetInFile)
                .help(state.isSetInFile ? "Reset to herdr's default" : "Already using herdr's default")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.label)
                    if entry.requiresRestart {
                        Text("restart").font(.caption2).padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(inputError ?? state.problem ?? entry.help)
                    .font(.caption)
                    .foregroundStyle(inputError != nil || state.problem != nil ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
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
                TextField("", text: $draft, prompt: Text(display(entry.defaultValue)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(entry.kind.isNumeric ? .trailing : .leading)
                    .frame(minWidth: entry.kind.isNumeric ? 80 : 180, maxWidth: entry.kind.isNumeric ? 100 : 260)
                    .focused($focused)
                    .onAppear { draft = display(state.value) }
                    .onChange(of: state.value) { newValue in
                        // Adopt outside changes (reset, revert) but never
                        // rewrite what the user is mid-way through typing.
                        if HerdrConfigInput.value(from: draft, for: entry) != .success(newValue) {
                            draft = display(newValue)
                        }
                    }
                    .onChange(of: draft) { _ in commit(state, final: false) }
                    .onChange(of: focused) { isFocused in if !isFocused { commit(state, final: true) } }
                    .onSubmit { commit(state, final: true) }
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

    /// Live commits keep Save enabled as soon as a valid value is typed (a
    /// value only committed on Return left Save disabled). `final` (Return or
    /// focus loss) also resolves an emptied numeric/color field to "reset".
    private func commit(_ state: HerdrConfigFieldState, final: Bool) {
        let isEmpty = draft.trimmingCharacters(in: .whitespaces).isEmpty
        if isEmpty, entry.kind != .text || entry.defaultValue == .string("") && entry.kind == .color {
            guard final else { return }
            inputError = nil
            if state.isSetInFile { store.unset(entry.path) }
            return
        }
        guard draft != display(state.value) else { inputError = nil; return }
        switch HerdrConfigInput.value(from: draft, for: entry) {
        case .success(let value):
            inputError = nil
            if value != state.value { store.set(entry.path, to: value) }
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
    @FocusState private var focused: Bool

    var body: some View {
        let state = HerdrKeyBindingState.resolve(action, in: store.document)
        LabeledContent {
            HStack(spacing: 6) {
                if state.isEditable {
                    TextField("", text: $draft, prompt: Text(action.defaultBinding ?? "unbound"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 170, maxWidth: 240)
                        .focused($focused)
                        .onAppear { draft = state.binding }
                        .onChange(of: state.binding) { newValue in
                            if draft.trimmingCharacters(in: .whitespaces) != newValue { draft = newValue }
                        }
                        .onChange(of: draft) { _ in commit(state, final: false) }
                        .onChange(of: focused) { isFocused in if !isFocused { commit(state, final: true) } }
                        .onSubmit { commit(state, final: true) }
                } else {
                    Text(state.rawText ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button {
                    store.unset(action.path)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!state.isSetInFile)
                .help(state.isSetInFile ? "Reset to herdr's default" : "Already using herdr's default")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.label)
                if let message = inputError ?? state.problem ?? conflictMessage(state) ?? readOnlyNote(state) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message == readOnlyNote(state) ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
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

    /// Valid bindings commit as you type (so Save enables immediately). An
    /// emptied field is only resolved on Return/focus loss, where it means
    /// "reset to herdr's default" -- resolving it mid-edit would snap the
    /// default back under the cursor.
    private func commit(_ state: HerdrKeyBindingState, final: Bool) {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            guard final else { return }
            inputError = nil
            if state.isSetInFile { store.unset(action.path) }
            return
        }
        guard trimmed != state.binding else { inputError = nil; return }
        switch HerdrKeyBindingInput.value(from: trimmed, for: action) {
        case .success(let value):
            inputError = nil
            store.set(action.path, to: value)
        case .failure(let error):
            inputError = error.message
        }
    }
}


/// One `[[keys.command]]` block. Fields commit on Return / picker change; each
/// commit is a pure document edit, so nothing reaches disk until Save.
private struct HerdrCommandRow: View {
    let index: Int
    let command: HerdrCustomCommand
    @EnvironmentObject private var store: HerdrConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Command \(index + 1)").font(.headline)
                Spacer()
                Button(role: .destructive) {
                    store.apply { $0.removingArrayTable(HerdrCustomCommand.tablePath, at: index) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this command")
            }
            if command.isFormEditable {
                field("Key", "key", command.key, mono: true)
                Picker("Type", selection: Binding(
                    get: { command.type },
                    set: { newType in
                        store.apply { doc in
                            doc.settingInArrayTable(HerdrCustomCommand.tablePath, at: index, key: "type", to: .string(newType))
                        }
                    }
                )) {
                    ForEach(HerdrCustomCommand.types.filter { $0 != "plugin_action" }, id: \.self) { Text($0).tag($0) }
                }
                field("Command", "command", command.command, mono: true)
                field("Description", "description", command.description, optional: true)
                if command.type == "popup" {
                    field("Width", "width", command.width, optional: true, placeholder: "80%")
                    field("Height", "height", command.height, optional: true, placeholder: "80%")
                }
                ForEach(command.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            } else {
                Text("plugin_action command — edit it in the Raw tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func field(_ title: String, _ name: String, _ value: String, mono: Bool = false,
                       optional: Bool = false, placeholder: String = "") -> some View {
        HerdrCommandField(title: title, value: value, mono: mono, placeholder: placeholder) { text in
            store.apply { doc in
                if optional, text.isEmpty {
                    return doc.unsettingInArrayTable(HerdrCustomCommand.tablePath, at: index, key: name)
                }
                return doc.settingInArrayTable(HerdrCustomCommand.tablePath, at: index, key: name, to: .string(text))
            }
        }
    }
}

private struct HerdrCommandField: View {
    let title: String
    let value: String
    let mono: Bool
    let placeholder: String
    let commit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField(title, text: $draft, prompt: Text(placeholder))
            .font(mono ? .system(.body, design: .monospaced) : .body)
            .onAppear { draft = value }
            .onChange(of: value) { draft = $0 }
            .onSubmit { commit(draft) }
    }
}


/// Editor for one sidebar `rows` list: one comma-separated text field per row.
/// Styled tokens can't be represented here, so such a value is shown read-only.
private struct HerdrSidebarRowsSection: View {
    let kind: HerdrSidebarRows.Kind
    let title: String
    @EnvironmentObject private var store: HerdrConfigStore

    var body: some View {
        let fileValue = store.document.value(at: kind.path)
        let isSet = fileValue != nil
        let rows: [[String]]? = {
            guard let fileValue else { return HerdrSidebarRows.defaultRows(for: kind) }
            if case .raw(let source) = fileValue { return HerdrSidebarRows.parse(source: source) }
            return nil
        }()
        Section {
            if let rows {
                ForEach(rows.indices, id: \.self) { index in
                    HStack {
                        HerdrRowTextField(value: rows[index].joined(separator: ", ")) { text in
                            var updated = rows
                            updated[index] = HerdrSidebarRows.tokens(fromRowText: text)
                            write(updated)
                        }
                        Button {
                            var updated = rows
                            updated.remove(at: index)
                            write(updated)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    write(rows + [["agent"]])
                } label: {
                    Label("Add row", systemImage: "plus")
                }
                ForEach(HerdrSidebarRows.problems(in: rows, for: kind), id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.red)
                }
            } else {
                Text(fileValue?.sourceText ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Contains styled tokens or a shape this editor doesn't handle — edit it in the Raw tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if isSet {
                    Button("Use default") { store.unset(kind.path) }.buttonStyle(.borderless)
                }
            }
        } footer: {
            Text("Tokens: \(kind.builtinTokens.joined(separator: ", ")), or $name for reported metadata. "
                + "Comma-separated within a row.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func write(_ rows: [[String]]) {
        store.set(kind.path, to: .raw(HerdrSidebarRows.format(rows)))
    }
}

private struct HerdrRowTextField: View {
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("tokens", text: $draft)
            .font(.system(.body, design: .monospaced))
            .onAppear { draft = value }
            .onChange(of: value) { draft = $0 }
            .onSubmit { commit(draft) }
    }
}
