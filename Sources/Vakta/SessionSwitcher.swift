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

/// Backing state for the palette. Owns the query, the current highlight, and
/// the match computation, so both the SwiftUI view (rendering) and the panel
/// (key handling) act on one source of truth. Items span three categories --
/// sessions, herdr workspaces, and static actions (see `PaletteItem`) -- so
/// the palette can jump to or run any of them from one flat list.
@MainActor
final class SessionSwitcherModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            highlighted = 0
            onQueryChanged?(query)
        }
    }
    @Published var highlighted: Int = 0
    @Published private(set) var scope: PaletteNavigationScope = .root

    @Published private(set) var items: [PaletteItem] = []
    private var rootItems: [PaletteItem] = []
    private var globalPaneItems: [PaletteItem] = []
    private var parentScopes: [(scope: PaletteNavigationScope, items: [PaletteItem])] = []
    /// Bumped on every `reset`; tags an in-flight async fetch (e.g. a herdr
    /// session's workspaces) so a result that lands after the palette was
    /// closed and reopened doesn't get appended to the wrong list -- see
    /// `PaletteAppendPlanner`.
    private(set) var generation = 0

    /// Called with the chosen item (Enter or click).
    var onSelect: ((PaletteItem) -> Void)?
    /// Called when the panel receives a raw navigation intent. Kept as a
    /// small seam for panel tests and alternate hosts.
    var onNavigation: ((PaletteNavigationIntent) -> Void)?
    /// Called when the shell should refresh data for the current query mode.
    var onQueryChanged: ((String) -> Void)?
    /// Called when Tab identifies a child scope whose rows must be fetched by
    /// the shell. The model never performs process I/O itself.
    var onScopeRequested: ((PaletteNavigationScope) -> Void)?
    /// Called on ⎋ at the root, or when a nested navigation request dismisses
    /// the palette.
    var onCancel: (() -> Void)?

    /// Re-seeds the palette for a fresh open. Returns the new generation, to
    /// tag any async fetch started for this open (see `append`).
    @discardableResult
    func reset(items: [PaletteItem]) -> Int {
        generation += 1
        parentScopes.removeAll()
        scope = .root
        rootItems = items
        globalPaneItems.removeAll()
        self.items = items
        query = ""
        highlighted = 0
        return generation
    }

    /// Replaces the visible rows with a child scope while retaining the
    /// current scope and rows for Shift-Tab/Escape backtracking.
    func showScope(_ newScope: PaletteNavigationScope, items: [PaletteItem]) {
        guard newScope != scope else {
            self.items = items
            query = ""
            highlighted = 0
            return
        }
        parentScopes.append((scope: scope, items: self.items))
        scope = newScope
        self.items = items
        query = ""
        highlighted = 0
    }

    /// Restores the previous scope and rows. Returns false at the root.
    @discardableResult
    func goBack() -> Bool {
        guard let previous = parentScopes.popLast() else { return false }
        scope = previous.scope
        items = previous.items
        query = ""
        highlighted = 0
        return true
    }

    /// Resolves a navigation intent against the current highlighted row. The
    /// shell supplies asynchronously fetched rows for a requested child
    /// scope; backtracking is handled locally because parent rows are cached.
    func navigate(_ intent: PaletteNavigationIntent) {
        onNavigation?(intent)
        let currentMatches = matches
        guard currentMatches.indices.contains(highlighted) else {
            if intent == .escape || intent == .shiftTab {
                if scope == .root { onCancel?() } else { _ = goBack() }
            }
            return
        }
        let outcome = PaletteNavigationPlanner.decide(
            intent: intent,
            highlighted: currentMatches[highlighted],
            scope: scope
        )
        switch outcome {
        case .drillInto(let childScope):
            onScopeRequested?(childScope)
        case .back:
            _ = goBack()
        case .dismiss:
            onCancel?()
        case .commit(let kind):
            if let item = currentMatches.first(where: { $0.kind == kind }) {
                onSelect?(item)
            }
        case .noOp:
            break
        }
    }

    /// Replaces rows for the currently visible scope without resetting the
    /// user's query or highlight. Used when an asynchronous fetch completes.
    func replaceScopeItems(_ newItems: [PaletteItem], for scope: PaletteNavigationScope) {
        guard self.scope == scope else { return }
        items = newItems
    }

    /// Merges asynchronously-fetched items (e.g. a herdr session's
    /// workspaces) into the current list -- a no-op if the palette has since
    /// been reset (closed/reopened) after `forGeneration` was captured.
    func append(_ newItems: [PaletteItem], forGeneration: Int) {
        guard PaletteAppendPlanner.shouldApply(fetchGeneration: forGeneration, currentGeneration: generation) else { return }
        items += newItems
    }

    /// The always-refresh counterpart to `append`, for a session whose
    /// workspace rows were already present at open time (from a previous
    /// fetch): drops `sessionID`'s existing `.focusWorkspace` rows and
    /// appends the freshly-queried batch, so a workspace created since the
    /// last fetch shows up without a stale duplicate alongside it. Same
    /// stale-generation guard as `append`; behaves like `append` when
    /// `sessionID` had no prior rows.
    func replaceWorkspaces(_ newItems: [PaletteItem], forSessionID sessionID: UUID, forGeneration: Int) {
        guard PaletteAppendPlanner.shouldApply(fetchGeneration: forGeneration, currentGeneration: generation) else { return }

        func replacingRows(in rows: [PaletteItem]) -> [PaletteItem] {
            rows.filter {
                if case .focusWorkspace(let existingSessionID, _) = $0.kind { return existingSessionID != sessionID }
                return true
            } + newItems
        }

        if scope == .root {
            rootItems = replacingRows(in: rootItems)
            items = rootItems + globalPaneItems
        } else {
            items = replacingRows(in: items)
        }
    }

    /// Replaces the cached global pane rows for the current palette open.
    /// They remain hidden while the query is in normal mode and are projected
    /// when the user enters the `@` search mode.
    func replaceGlobalPaneItems(_ newItems: [PaletteItem], forGeneration: Int) {
        guard PaletteAppendPlanner.shouldApply(fetchGeneration: forGeneration, currentGeneration: generation) else { return }
        globalPaneItems = newItems
        guard scope == .root else { return }
        items = rootItems + globalPaneItems
    }

    /// Case-insensitive substring match on title/subtitle; empty query shows all.
    var matches: [PaletteItem] {
        let visibleItems: [PaletteItem]
        if scope == .root, PaletteQuery.parse(query).mode == .normal {
            let globalIDs = Set(globalPaneItems.map(\.id))
            visibleItems = items.filter { !globalIDs.contains($0.id) }
        } else {
            visibleItems = items
        }
        return PaletteMatcher.matches(query: query, in: visibleItems)
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
        onSelect?(matches[highlighted])
    }

    func cancel() { onCancel?() }
}

/// A key-capable floating panel that routes navigation keys to its model and
/// lets everything else (typing) fall through to the search field.
final class SessionSwitcherPanel: NSPanel {
    weak var model: SessionSwitcherModel?

    /// Whether the search field's field editor currently owns an
    /// in-progress input-method composition (marked text). A closure --
    /// rather than reading `firstResponder` inline -- so a test can supply a
    /// real, standalone `NSTextView` with `setMarkedText` actually called on
    /// it, without needing this panel to be key or even on screen.
    lazy var hasMarkedTextProvider: () -> Bool = { [weak self] in
        (self?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model {
            // `sendEvent` runs on the main thread in AppKit; assert isolation
            // to call the model's main-actor API without a hop that would let
            // the key fall through first.
            let handled = MainActor.assumeIsolated { () -> Bool in
                let intent = SessionSwitcherKeyRouter.intent(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    hasMarkedText: hasMarkedTextProvider()
                )
                switch intent {
                case .moveDown: model.moveDown(); return true
                case .moveUp: model.moveUp(); return true
                case .commit: model.commit(); return true
                case .cancel: model.navigate(.escape); return true
                case .drillDown: model.navigate(.tab); return true
                case .back: model.navigate(.shiftTab); return true
                case .passthrough: return false
                }
            }
            if handled { return }
        }
        super.sendEvent(event)
    }
}

struct SessionSwitcherView: View {
    @ObservedObject var model: SessionSwitcherModel
    /// The row highlight, background, and tint -- all passed in from the
    /// current terminal theme (see `AppDelegate.showSessionSwitcher`) so the
    /// palette reads as part of the same surface as the sidebar/terminal,
    /// not a generic system panel.
    var highlightColor: Color = .accentColor
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var accentColor: Color = .accentColor
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
                            Text("No matches")
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
                                    .onTapGesture { model.onSelect?(item) }
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
        // A solid theme-background fill, not a translucent material -- same
        // choice `makeWindow` documents for the sidebar/terminal seam: the
        // goal is to match the terminal's actual background, which vibrancy
        // can't do.
        .background(backgroundColor)
        .tint(accentColor)
        .onAppear {
            // Focusing the field in the same runloop turn the hosting panel is
            // ordered in is racy (the panel may not be key yet); defer a turn.
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            // Actions have no live status to show; a session/workspace row
            // gets its usual colored dot.
            if item.category != .action {
                Circle()
                    .fill(sidebarStatusColor(item.status, isFocused: false))
                    .frame(width: 7, height: 7)
            }
            Text(item.title)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
