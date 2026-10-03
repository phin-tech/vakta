//
//  ExtensionPanelView.swift
//  Vakta
//
//  Draws an Extension's Panel View natively in the right-hand panel from its
//  View Document: a filterable list of sections and rows, an item's detail
//  with a back button, and loading / unavailable / error states. A
//  projection of `PanelViewStore`; no decisions here.

import AppKit
import SwiftUI
import VaktaExtensionKit

struct ExtensionPanelView: View {
    @EnvironmentObject private var store: PanelViewStore
    @EnvironmentObject private var host: ExtensionHost
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var sessionStore: SessionStore

    private var terminalStyle: Bool { appearanceStore.sidebarFont == .matchTerminal }
    private var accent: Color { Color(nsColor: sessionStore.terminalAccentColor) }
    private var selection: Color { Color(nsColor: sessionStore.terminalSelectionColor) }

    var body: some View {
        content
            .overlay(alignment: .bottom) { toast }
            .panelShortcuts(buttons: shortcutButtons, isShowingDetail: store.model.isShowingDetail, back: store.back, press: press)
    }

    @ViewBuilder
    private var toast: some View {
        if let text = store.toast {
            Text(text)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 10)
                .transition(.opacity)
        }
    }

    /// Buttons whose shortcuts apply now: the visible detail's, or the
    /// selected row's.
    private var shortcutButtons: [ViewButton] {
        switch store.model.visibleDocument {
        case .detail(let detail)?:
            return detail.buttons
        case .form(let form)?:
            return [form.submit]
        case .list(let list)?:
            guard let id = store.model.selectedItemID else { return [] }
            return list.sections.lazy.flatMap(\.items).first { $0.id == id }?.buttons ?? []
        default:
            return []
        }
    }

    private func press(_ button: ViewButton) {
        if case .form(let form)? = store.model.visibleDocument, button == form.submit {
            store.submitForm(form)
        } else {
            store.press(button)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.model.content {
        case .loading:
            placeholder(symbol: "hourglass", text: "Loading…")
        case .unavailable(let message):
            placeholder(symbol: "exclamationmark.triangle", text: message) {
                if let id = store.active?.extensionID {
                    HStack {
                        Button("Restart") { host.restart(id) }
                        Button("View Log") { NSWorkspace.shared.open(host.logURL(for: id)) }
                    }
                    .controlSize(.small)
                }
            }
        case .error(let message):
            placeholder(symbol: "exclamationmark.triangle", text: message) {
                Button("Try Again") { store.refresh() }.controlSize(.small)
            }
        case .document:
            if let document = store.model.visibleDocument {
                if !store.model.isShowingDetail {
                    root(document)
                } else {
                    detailScreen(document)
                }
            }
        }
    }

    // MARK: - Root

    @ViewBuilder
    private func root(_ document: ViewDocument) -> some View {
        switch document {
        case .list(let list):
            listScreen(list)
        case .detail(let detail):
            ScrollView { DocumentDetail(detail: detail, terminalStyle: terminalStyle) }
        case .form(let form):
            ScrollView { DocumentForm(form: form, terminalStyle: terminalStyle) }
        case .unsupported:
            placeholder(symbol: "questionmark.square.dashed", text: "This view needs a newer Vakta.")
        }
    }

    private func listScreen(_ list: ListView) -> some View {
        let filtered = store.model.filteredList ?? list
        return VStack(spacing: 0) {
            if !list.buttons.isEmpty {
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(Array(list.buttons.enumerated()), id: \.offset) { _, button in
                        DocumentButton(button: button, compact: false)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            if let prompt = list.searchPlaceholder {
                TextField(prompt, text: Binding(get: { store.model.filter }, set: { store.setFilter($0) }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            if filtered.sections.allSatisfy(\.items.isEmpty) {
                placeholder(
                    symbol: "tray",
                    text: store.model.filter.isEmpty ? (list.emptyText ?? "Nothing here") : "No matches"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: terminalStyle ? 0 : 1) {
                        ForEach(Array(filtered.sections.enumerated()), id: \.offset) { _, section in
                            if let title = section.title {
                                Text(terminalStyle ? title.uppercased() : title)
                                    .font(.system(size: 10, weight: .semibold, design: terminalStyle ? .monospaced : .default))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.items, id: \.id) { item in
                                ItemRow(
                                    item: item,
                                    isSelected: store.model.selectedItemID == item.id,
                                    terminalStyle: terminalStyle,
                                    accent: accent,
                                    selection: selection,
                                    select: { store.select(item.id) },
                                    open: { store.openDetail(item.id) }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, terminalStyle ? 0 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Detail

    private func detailScreen(_ document: ViewDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // No window-wide key equivalent: Escape belongs to the terminal.
            // `panelShortcuts` handles it while the panel has focus.
            Button {
                store.back()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().opacity(0.5)
            ScrollView {
                if case .detail(let detail) = document {
                    DocumentDetail(detail: detail, terminalStyle: terminalStyle)
                } else if case .form(let form) = document {
                    DocumentForm(form: form, terminalStyle: terminalStyle)
                } else {
                    Text("This view needs a newer Vakta.").foregroundStyle(.secondary).padding()
                }
            }
        }
    }

    // MARK: - States

    private func placeholder(symbol: String, text: String) -> some View {
        placeholder(symbol: symbol, text: text) { EmptyView() }
    }

    private func placeholder<Actions: View>(symbol: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(terminalStyle ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            actions()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ItemRow: View {
    @State private var isHovered = false
    let item: ListItem
    let isSelected: Bool
    let terminalStyle: Bool
    let accent: Color
    let selection: Color
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                    .frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(terminalStyle ? .system(size: 11, design: .monospaced) : .system(size: 12))
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: terminalStyle ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ForEach(Array(item.accessories.enumerated()), id: \.offset) { _, accessory in
                HStack(spacing: 2) {
                    if let symbol = accessory.symbol { Image(systemName: symbol) }
                    Text(accessory.text)
                }
                .font(.system(size: 9, design: terminalStyle ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: terminalStyle ? 0 : 3).fill(Color.primary.opacity(0.06)))
            }
            if (isHovered || isSelected) && !item.buttons.isEmpty {
                ForEach(Array(item.buttons.enumerated()), id: \.offset) { _, button in
                    DocumentButton(button: button, compact: true)
                }
            } else if item.detail != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .onHover { isHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: terminalStyle ? 0 : 4)
                .fill(isSelected ? selection.opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Open", open)
    }
}

/// A detail View Document: title, labelled fields, and a markdown body.
struct DocumentDetail: View {
    let detail: DetailView
    let terminalStyle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.title)
                .font(terminalStyle ? .system(size: 12, weight: .semibold, design: .monospaced) : .system(size: 13, weight: .semibold))
                .textSelection(.enabled)
            if !detail.fields.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(Array(detail.fields.enumerated()), id: \.offset) { _, field in
                        GridRow {
                            Text(field.label).foregroundStyle(.secondary)
                            Text(field.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 11, design: terminalStyle ? .monospaced : .default))
            }
            if !detail.buttons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(detail.buttons.enumerated()), id: \.offset) { _, button in
                        DocumentButton(button: button, compact: false)
                    }
                }
            }
            if let markdown = detail.markdown {
                Text(Self.attributed(markdown))
                    .font(.system(size: 11, design: terminalStyle ? .monospaced : .default))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown with line breaks kept; block elements (headings,
    /// lists) render as their text.
    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

/// A form View Document drawn with native controls. Edits live in the store
/// (`FormState`) so they survive re-renders of the list underneath.
struct DocumentForm: View {
    @EnvironmentObject private var store: PanelViewStore
    let form: FormView
    let terminalStyle: Bool

    private var state: FormState { store.formState(for: form) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(form.title)
                .font(terminalStyle ? .system(size: 12, weight: .semibold, design: .monospaced) : .system(size: 13, weight: .semibold))
            ForEach(form.fields, id: \.id) { field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.required ? "\(field.label) *" : field.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    control(for: field)
                    if state.attemptedSubmit, let problem = state.problems[field.id] {
                        Text(problem).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Button("Cancel") { store.back() }
                    .controlSize(.small)
                Spacer()
                SubmitButton(form: form)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func control(for field: FormField) -> some View {
        switch field.kind {
        case .text(let placeholder, _):
            TextField(placeholder ?? "", text: textBinding(field.id))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        case .multiline:
            TextEditor(text: textBinding(field.id))
                .font(.system(size: 11, design: terminalStyle ? .monospaced : .default))
                .frame(minHeight: 70, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
        case .picker(let options, _):
            Picker(field.label, selection: Binding(
                get: { state.choice(field.id) ?? "" },
                set: { value in store.editForm(form) { $0.setChoice(field.id, value.isEmpty ? nil : value) } }
            )) {
                if !field.required { Text("None").tag("") }
                ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) }
            }
            .labelsHidden()
            .controlSize(.small)
        case .toggle:
            Toggle(field.label, isOn: Binding(
                get: { state.isOn(field.id) },
                set: { value in store.editForm(form) { $0.setToggle(field.id, value) } }
            ))
            .controlSize(.small)
        case .unsupported:
            Text("This field needs a newer Vakta.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { state.text(id) }, set: { value in store.editForm(form) { $0.setText(id, value) } })
    }
}

/// A form's submit button: validates through the store before sending.
private struct SubmitButton: View {
    @EnvironmentObject private var store: PanelViewStore
    let form: FormView

    var body: some View {
        let state = store.callbackState(form.submit)
        VStack(alignment: .trailing, spacing: 2) {
            Button(role: form.submit.style == .destructive ? .destructive : nil) {
                store.submitForm(form)
            } label: {
                if state == .pending { ProgressView().controlSize(.mini) } else { Text(form.submit.title) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state == .pending)
            if case .failed(let message) = state {
                Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(4)
            }
        }
    }
}

/// A View Document button: asks for confirmation when the document says so,
/// shows a spinner while its Callback runs and the failure if it fails.
struct DocumentButton: View {
    @EnvironmentObject private var store: PanelViewStore
    let button: ViewButton
    let compact: Bool
    @State private var isConfirming = false

    private var state: CallbackTracker.State { store.callbackState(button) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            control
            if !compact, case .failed(let message) = state {
                Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(3)
            }
        }
        .confirmationDialog(
            button.confirm?.title ?? button.title,
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(button.confirm?.button ?? button.title, role: button.style == .destructive ? .destructive : nil) {
                store.press(button)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message = button.confirm?.message { Text(message) }
        }
    }

    @ViewBuilder
    private var control: some View {
        let styled = Button(role: button.style == .destructive ? .destructive : nil, action: activate) {
            if state == .pending {
                ProgressView().controlSize(.mini)
            } else if compact, let symbol = button.symbol {
                Image(systemName: symbol)
            } else if let symbol = button.symbol {
                Label(button.title, systemImage: symbol)
            } else {
                Text(button.title)
            }
        }
        .controlSize(.small)
        .disabled(state == .pending)
        .help(helpText)
        .accessibilityLabel(button.title)
        if button.style == .primary && !compact {
            styled.buttonStyle(.borderedProminent)
        } else if compact {
            styled.buttonStyle(.borderless)
        } else {
            styled.buttonStyle(.bordered)
        }
    }

    private var helpText: String {
        var text = button.title
        if let shortcut = button.shortcut.flatMap(ButtonShortcut.parse) { text += " (\(shortcut.symbol))" }
        if case .failed(let message) = state { text += " — \(message)" }
        return text
    }

    private func activate() {
        if button.confirm != nil {
            isConfirming = true
        } else {
            store.press(button)
        }
    }
}

private extension View {
    /// Button shortcuts and Escape-for-Back, active only while the panel has
    /// keyboard focus (never as window-wide key equivalents, which would take
    /// keys from the terminal). Needs macOS 14's key-press handling; on
    /// macOS 13 buttons work by click only.
    @ViewBuilder
    func panelShortcuts(
        buttons: [ViewButton], isShowingDetail: Bool, back: @escaping () -> Void, press: @escaping (ViewButton) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            self
                .focusable()
                .focusEffectDisabled()
                .onKeyPress { keyPress in
                    if keyPress.key == .escape, keyPress.modifiers.isEmpty, isShowingDetail {
                        back()
                        return .handled
                    }
                    for button in buttons {
                        guard let shortcut = button.shortcut.flatMap(ButtonShortcut.parse),
                              shortcut.matches(keyPress) else { continue }
                        press(button)
                        return .handled
                    }
                    return .ignored
                }
        } else {
            self
        }
    }
}

@available(macOS 14.0, *)
private extension ButtonShortcut {
    func matches(_ keyPress: KeyPress) -> Bool {
        var pressed: Modifiers = []
        if keyPress.modifiers.contains(.command) { pressed.insert(.command) }
        if keyPress.modifiers.contains(.shift) { pressed.insert(.shift) }
        if keyPress.modifiers.contains(.option) { pressed.insert(.option) }
        if keyPress.modifiers.contains(.control) { pressed.insert(.control) }
        guard pressed == modifiers else { return false }
        switch key {
        case .character(let character): return keyPress.characters.lowercased() == String(character)
        case .return: return keyPress.key == .return
        case .escape: return keyPress.key == .escape
        case .delete: return keyPress.key == .delete
        case .tab: return keyPress.key == .tab
        case .space: return keyPress.key == .space
        case .up: return keyPress.key == .upArrow
        case .down: return keyPress.key == .downArrow
        case .left: return keyPress.key == .leftArrow
        case .right: return keyPress.key == .rightArrow
        }
    }
}
