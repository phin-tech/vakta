//
//  PanelViews.swift
//  Vakta
//
//  Pure decisions for Extension Panel Views in the right-hand panel: which
//  mode is actually shown when the saved one isn't available, how the mode
//  toggle splits buttons from overflow, and the state of the view on screen
//  (document, filter, selection, detail navigation, stale results).

import Foundation
import VaktaExtensionKit

/// A Panel View offered by a ready Extension, as the mode toggle shows it.
struct PanelViewOption: Equatable, Identifiable {
    var ref: PanelViewRef
    var title: String
    var symbol: String
    var id: PanelViewRef { ref }
}

enum PanelModeResolver {
    /// Extension buttons shown inline in the toggle; the rest go in a menu.
    static let inlineLimit = 2

    /// The saved mode when it's available, otherwise Files. The saved mode
    /// itself is left alone so it comes back when the Extension does.
    static func effectiveMode(saved: FileSidebarMode, available: [PanelViewOption]) -> FileSidebarMode {
        guard case .extensionView(let ref) = saved else { return saved }
        return available.contains(where: { $0.ref == ref }) ? saved : .files
    }

    /// Panel Views of ready Extensions, in link order.
    static func options(from entries: [ExtensionEntry]) -> [PanelViewOption] {
        entries.flatMap { entry -> [PanelViewOption] in
            guard entry.status == .ready, let manifest = entry.manifest else { return [] }
            return manifest.panelViews.map {
                PanelViewOption(ref: PanelViewRef(extensionID: manifest.id, viewID: $0.id), title: $0.title, symbol: $0.symbol)
            }
        }
    }

    static func split(_ options: [PanelViewOption]) -> (inline: [PanelViewOption], overflow: [PanelViewOption]) {
        (Array(options.prefix(inlineLimit)), Array(options.dropFirst(inlineLimit)))
    }
}

struct PanelViewModel: Equatable {
    enum Content: Equatable {
        case loading
        case document(ViewDocument)
        /// The Extension isn't running; `message` says why.
        case unavailable(String)
        /// Rendering failed (the Extension answered with an error or junk).
        case error(String)
    }

    private(set) var content: Content = .loading
    var filter = ""
    /// One screen above the root list.
    enum PathEntry: Equatable {
        /// A list item's own detail (follows live updates of that item).
        case item(String)
        /// A document an Extension pushed.
        case document(ViewDocument)
    }

    private(set) var selectedItemID: String?
    /// Screens shown above the root, innermost last.
    private(set) var path: [PathEntry] = []
    /// Bumped whenever results from earlier requests become stale.
    private(set) var generation = 0

    /// Starts a new request; returns its generation. Keeps showing the
    /// current document while reloading.
    mutating func beginRender() -> Int {
        generation
    }

    /// Applies a document an Extension pushed unprompted (`view/update`).
    /// Bumps the generation so a `view/render` response already in flight
    /// (captured an earlier token) is dropped as stale if it arrives after.
    @discardableResult
    mutating func applyPush(_ document: ViewDocument) -> Bool {
        guard apply(document, generation: generation) else { return false }
        generation += 1
        return true
    }

    /// Applies a document from `generation`; `false` (and no change) when stale.
    @discardableResult
    mutating func apply(_ document: ViewDocument, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        content = .document(document)
        // Keep navigation that still points at something; drop the rest.
        if let selected = selectedItemID, item(selected, in: document) == nil {
            selectedItemID = nil
        }
        if let index = path.firstIndex(where: { entry in
            if case .item(let id) = entry { return item(id, in: document)?.detail == nil }
            return false
        }) {
            path.removeSubrange(index...)
        }
        return true
    }

    mutating func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        content = .error(message)
    }

    mutating func markUnavailable(_ message: String) {
        content = .unavailable(message)
        path = []
    }

    /// The focused Session changed to a place shown before: show its last
    /// document right away (a fresh render replaces it); earlier results are
    /// stale and the navigation no longer applies.
    mutating func reset(showing cached: ViewDocument) {
        reset()
        content = .document(cached)
    }

    /// The focused Session changed: earlier results are stale and the
    /// navigation no longer applies.
    mutating func reset() {
        generation += 1
        content = .loading
        filter = ""
        selectedItemID = nil
        path = []
    }

    mutating func select(_ itemID: String?) {
        selectedItemID = itemID
    }

    /// Shows the item's detail when it has one (and selects it either way).
    mutating func openDetail(_ itemID: String) {
        selectedItemID = itemID
        guard case .document(let document) = content, item(itemID, in: document)?.detail != nil else { return }
        path = [.item(itemID)]
    }

    mutating func back() {
        _ = path.popLast()
    }

    /// Pushes a document an Extension returned (a `push` Effect).
    mutating func push(_ document: ViewDocument) {
        guard case .document = content else { return }
        path.append(.document(document))
    }

    /// Replaces what's on screen (a `replace` Effect): the innermost screen,
    /// else the root.
    mutating func replaceVisible(_ document: ViewDocument) {
        if path.isEmpty {
            content = .document(document)
        } else {
            path[path.count - 1] = .document(document)
        }
    }

    /// Whether anything is open above the root list (item detail or pushed).
    var isShowingDetail: Bool { !path.isEmpty }

    /// What's on screen: the innermost open detail, else the root document.
    var visibleDocument: ViewDocument? {
        guard case .document(let document) = content else { return nil }
        switch path.last {
        case .document(let pushed)?: return pushed
        case .item(let id)?: return item(id, in: document)?.detail ?? document
        case nil: return document
        }
    }

    /// The root list narrowed by `filter`.
    var filteredList: ListView? {
        guard case .document(.list(let list)) = content else { return nil }
        return Self.filter(list, query: filter)
    }

    static func filter(_ list: ListView, query: String) -> ListView {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return list }
        var filtered = list
        filtered.sections = list.sections.compactMap { section in
            let items = section.items.filter { item in
                ([item.id, item.title, item.subtitle].compactMap { $0 } + item.accessories.map(\.text))
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            guard !items.isEmpty else { return nil }
            var kept = section
            kept.items = items
            return kept
        }
        return filtered
    }

    private func item(_ id: String, in document: ViewDocument) -> ListItem? {
        guard case .list(let list) = document else { return nil }
        for section in list.sections {
            if let match = section.items.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}
