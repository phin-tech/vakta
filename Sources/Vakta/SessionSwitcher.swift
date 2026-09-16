//
//  SessionSwitcher.swift
//  Vakta
//
//  A ⌘K command-palette for jumping to a session by name: a floating panel
//  with a search field and a filtered, keyboard-navigable list. Bound to ⌘K by
//  default (rebindable/clearable under Preferences ▸ Keybindings). Because that
//  chord goes through `KeybindingMatcher`, which consumes on match (settled
//  design decision #6), binding ⌘K shadows it for herdr -- clear the binding to
//  give ⌘K back to the terminal.
//
//  Keyboard nav is done by a tiny `NSPanel` subclass rather than SwiftUI's
//  `onMoveCommand`: while the search `TextField` is first responder the
//  focused `NSTextView` swallows `moveUp:`/`moveDown:`, so those never reach a
//  SwiftUI handler. Intercepting keyDown in `sendEvent(_:)` before it is
//  dispatched to the field is the reliable path on macOS 13.

import AppKit
import SwiftUI

/// A flattened, display-ready snapshot of one session for the palette. Taken
/// once when the palette opens so the list doesn't churn as statuses poll.
struct SessionSwitcherItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let status: AgentStatus
}

/// Backing state for the palette. Owns the query, the current highlight, and
/// the match computation, so both the SwiftUI view (rendering) and the panel
/// (key handling) act on one source of truth.
@MainActor
final class SessionSwitcherModel: ObservableObject {
    @Published var query: String = "" { didSet { highlighted = 0 } }
    @Published var highlighted: Int = 0

    private(set) var items: [SessionSwitcherItem] = []

    /// Called with the chosen session id (Enter or click).
    var onSelect: ((UUID) -> Void)?
    /// Called on ⎋ or when the palette should dismiss without a choice.
    var onCancel: (() -> Void)?

    /// Re-seeds the palette for a fresh open.
    func reset(items: [SessionSwitcherItem]) {
        self.items = items
        query = ""
        highlighted = 0
    }

    /// Case-insensitive substring match on the title; empty query shows all.
    var matches: [SessionSwitcherItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(q) }
    }

    func moveDown() {
        let count = matches.count
        guard count > 0 else { return }
        highlighted = (highlighted + 1) % count
    }

    func moveUp() {
        let count = matches.count
        guard count > 0 else { return }
        highlighted = (highlighted - 1 + count) % count
    }

    func commit() {
        let matches = matches
        guard matches.indices.contains(highlighted) else { return }
        onSelect?(matches[highlighted].id)
    }

    func cancel() { onCancel?() }
}

/// A key-capable floating panel that routes navigation keys to its model and
/// lets everything else (typing) fall through to the search field.
final class SessionSwitcherPanel: NSPanel {
    weak var model: SessionSwitcherModel?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model {
            // `sendEvent` runs on the main thread in AppKit; assert isolation
            // to call the model's main-actor API without a hop that would let
            // the key fall through first.
            let handled = MainActor.assumeIsolated { () -> Bool in
                switch event.keyCode {
                case 125: model.moveDown(); return true // ↓
                case 126: model.moveUp(); return true   // ↑
                case 36:  model.commit(); return true   // ↩
                case 53:  model.cancel(); return true   // ⎋
                default:  return false
                }
            }
            if handled { return }
        }
        super.sendEvent(event)
    }
}

struct SessionSwitcherView: View {
    @ObservedObject var model: SessionSwitcherModel
    /// The row highlight, passed in so it matches the sidebar / herdr palette.
    var highlightColor: Color = .accentColor
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Switch to session…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // Enter also commits when the field has focus (belt and braces
                // with the panel's keyDown interception).
                .onSubmit { model.commit() }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let matches = model.matches
                        if matches.isEmpty {
                            Text("No matching sessions")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                row(item, isHighlighted: index == model.highlighted)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.onSelect?(item.id) }
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.highlighted) { highlighted in
                    let matches = model.matches
                    if matches.indices.contains(highlighted) {
                        proxy.scrollTo(matches[highlighted].id)
                    }
                }
            }
        }
        .frame(width: 440, height: 360)
        .background(.ultraThinMaterial)
        .onAppear {
            // Focusing the field in the same runloop turn the hosting panel is
            // ordered in is racy (the panel may not be key yet); defer a turn.
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    @ViewBuilder
    private func row(_ item: SessionSwitcherItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sidebarStatusColor(item.status, isFocused: false))
                .frame(width: 7, height: 7)
            Text(item.title)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? highlightColor : Color.clear)
        )
    }
}
