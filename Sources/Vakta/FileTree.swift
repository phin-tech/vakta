//
//  FileTree.swift
//  Vakta
//
//  The Files tree's state and layout. `FileTreeLayout.visibleRows` (pure)
//  flattens loaded directories into the rows the sidebar draws, so the view
//  can render one lazy list instead of nesting each expanded directory's
//  rows eagerly. `FileTreeModel` (shell) owns what's loaded and expanded and
//  reads directories off the main actor: lazily on expand, plus one level of
//  prefetch so opening a subfolder is instant.
//

import Foundation

struct FileTreeRow: Equatable, Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool
    let depth: Int
    let isExpanded: Bool

    var id: String { path }
}

enum FileTreeLayout {
    /// Depth-first rows under `root`: every loaded child of `root`, and the
    /// loaded children of each expanded directory beneath its row. An
    /// expanded directory that hasn't loaded yet shows expanded and empty.
    static func visibleRows(root: String, children: [String: [FileEntry]], expanded: Set<String>) -> [FileTreeRow] {
        rows(in: root, children: children, expanded: expanded, depth: 0)
    }

    static func path(of name: String, in directory: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func rows(in directory: String, children: [String: [FileEntry]], expanded: Set<String>, depth: Int) -> [FileTreeRow] {
        (children[directory] ?? []).flatMap { entry -> [FileTreeRow] in
            let path = path(of: entry.name, in: directory)
            let isExpanded = entry.isDirectory && expanded.contains(path)
            let row = FileTreeRow(path: path, name: entry.name, isDirectory: entry.isDirectory, depth: depth, isExpanded: isExpanded)
            guard isExpanded else { return [row] }
            return [row] + rows(in: path, children: children, expanded: expanded, depth: depth + 1)
        }
    }
}

@MainActor
final class FileTreeModel: ObservableObject {
    @Published private(set) var root: String?
    /// Sorted, filtered contents of each directory read so far.
    @Published private(set) var children: [String: [FileEntry]] = [:]
    @Published private(set) var expanded: Set<String> = []

    var rows: [FileTreeRow] {
        guard let root else { return [] }
        return FileTreeLayout.visibleRows(root: root, children: children, expanded: expanded)
    }

    var isRootLoaded: Bool { root.map { children[$0] != nil } ?? false }

    private let read: @Sendable (String) -> [FileEntry]?
    private let runInBackground: (@escaping @Sendable () -> Void) -> Void
    private let showHidden = false
    /// Bumped on every root change and reload; a read started under an
    /// older generation is dropped.
    private var generation = 0
    private var loading: Set<String> = []

    init(
        read: @escaping @Sendable (String) -> [FileEntry]? = { DirectoryReader.children(of: $0) },
        runInBackground: @escaping (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        }
    ) {
        self.read = read
        self.runInBackground = runInBackground
    }

    /// Shows `path` (nil clears the tree), forgetting expansion under the
    /// previous root.
    func setRoot(_ path: String?) {
        generation += 1
        root = path
        children = [:]
        expanded = []
        loading = []
        if let path { load(path, prefetchChildren: true) }
    }

    func toggle(_ path: String) {
        if expanded.remove(path) != nil { return }
        expanded.insert(path)
        if let loaded = children[path] {
            // Already read by a parent's prefetch; warm the next level.
            prefetchDirectories(in: path, entries: loaded)
        } else {
            load(path, prefetchChildren: true)
        }
    }

    /// Re-reads the root and every expanded directory, keeping them open.
    func reload() {
        guard let root else { return }
        generation += 1
        children = [:]
        loading = []
        load(root, prefetchChildren: true)
        for path in expanded { load(path, prefetchChildren: true) }
    }

    private func load(_ directory: String, prefetchChildren: Bool) {
        guard children[directory] == nil, !loading.contains(directory) else { return }
        loading.insert(directory)
        let requested = generation
        let read = self.read
        let showHidden = self.showHidden
        runInBackground { [weak self] in
            let entries = read(directory).map { DirectoryListing.sorted($0, showHidden: showHidden) } ?? []
            DispatchQueue.main.async { self?.finishLoad(directory, entries: entries, generation: requested, prefetchChildren: prefetchChildren) }
        }
    }

    private func finishLoad(_ directory: String, entries: [FileEntry], generation requested: Int, prefetchChildren: Bool) {
        guard requested == generation else { return }
        loading.remove(directory)
        children[directory] = entries
        if prefetchChildren { prefetchDirectories(in: directory, entries: entries) }
    }

    private func prefetchDirectories(in directory: String, entries: [FileEntry]) {
        for entry in entries where entry.isDirectory {
            load(FileTreeLayout.path(of: entry.name, in: directory), prefetchChildren: false)
        }
    }
}
