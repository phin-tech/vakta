//
//  TerminalSearchBar.swift
//  Vakta
//
//  The find bar floated over a session's terminal. Hosted by
//  `TerminalHostContainerView` as a sibling of the surface, never as its
//  owner (docs/architecture.md, "Permanent AppKit terminal host").

import SwiftUI

struct TerminalSearchBar: View {
    @ObservedObject var model: TerminalSearchModel
    @State private var needle = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find", text: $needle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { model.next() }
                .onChange(of: needle) { model.edit($0) }
                .onExitCommand { model.close() }
            Text(model.state.summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            Button { model.previous() } label: { Image(systemName: "chevron.up") }
            Button { model.next() } label: { Image(systemName: "chevron.down") }
            Button { model.close() } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .onAppear { sync() }
        .onChange(of: model.state.isActive) { if $0 { sync() } }
    }

    /// Shows the seed the core started with (the selection, say) and takes focus.
    private func sync() {
        needle = model.state.needle
        focused = true
    }
}
