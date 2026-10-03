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
                if store.model.detailPath.isEmpty {
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
        case .form, .unsupported:
            placeholder(symbol: "questionmark.square.dashed", text: "This view needs a newer Vakta.")
        }
    }

    private func listScreen(_ list: ListView) -> some View {
        let filtered = store.model.filteredList ?? list
        return VStack(spacing: 0) {
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
            .keyboardShortcut(.cancelAction)
            Divider().opacity(0.5)
            ScrollView {
                if case .detail(let detail) = document {
                    DocumentDetail(detail: detail, terminalStyle: terminalStyle)
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
            if item.detail != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
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
