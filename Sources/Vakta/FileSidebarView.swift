//
//  FileSidebarView.swift
//  Vakta
//
//  The right-hand file sidebar: a lazy, expandable tree of the selected
//  session's focused-pane working directory (`SessionStore.fileSidebarRoot`).
//  SwiftUI so it matches the left sidebar's chrome; lazy in the way that
//  matters -- a directory's children are read (via `DirectoryReader`, off the
//  main thread) only when that node is expanded, never the whole subtree up
//  front. Read-only: double-click opens a file in its default app; the context
//  menu reveals in Finder or opens.
//

import AppKit
import SwiftUI

/// One node in the file tree. A reference type so each row observes just its
/// own expansion/children, and so a directory can load its contents lazily on
/// first expansion without the parent re-reading anything.
@MainActor
final class FileNode: ObservableObject, Identifiable {
    let url: URL
    let isDirectory: Bool
    let showHidden: Bool
    nonisolated var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// `nil` until first loaded, so an unexpanded directory costs nothing.
    @Published var children: [FileNode]?
    @Published var isExpanded = false
    @Published var isLoading = false

    private let read: (String) -> [FileEntry]?

    init(
        url: URL,
        isDirectory: Bool,
        showHidden: Bool,
        read: @escaping (String) -> [FileEntry]? = DirectoryReader.children
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.showHidden = showHidden
        self.read = read
    }

    func toggleExpansion() {
        guard isDirectory else { return }
        isExpanded.toggle()
        guard isExpanded else { return }
        if children == nil {
            loadChildren(prefetchChildren: true)
        } else {
            // Already warmed by a parent's prefetch; warm the *next* level now
            // so drilling deeper stays instant.
            for child in children ?? [] where child.isDirectory { child.prefetch() }
        }
    }

    /// Loads this directory's contents without expanding it, so a later expand
    /// is instant. One level only -- it does not prefetch its own children's
    /// children (that happens when this node is actually expanded).
    func prefetch() {
        guard isDirectory, children == nil, !isLoading else { return }
        loadChildren(prefetchChildren: false)
    }

    /// Re-reads this directory's contents (a manual refresh, or after the root
    /// moved), preserving nothing stale.
    func reload() {
        guard isDirectory else { return }
        children = nil
        if isExpanded { loadChildren(prefetchChildren: true) }
    }

    private func loadChildren(prefetchChildren: Bool) {
        guard !isLoading, children == nil else { return }
        isLoading = true
        let directory = url
        let hidden = showHidden
        let read = self.read
        DispatchQueue.global(qos: .userInitiated).async {
            let sorted = read(directory.path).map { DirectoryListing.sorted($0, showHidden: hidden) } ?? []
            let nodes = sorted.map { entry in
                FileNode(
                    url: directory.appendingPathComponent(entry.name, isDirectory: entry.isDirectory),
                    isDirectory: entry.isDirectory,
                    showHidden: hidden,
                    read: read
                )
            }
            DispatchQueue.main.async {
                self.children = nodes
                self.isLoading = false
                // Warm one level ahead so opening a subfolder is instant.
                if prefetchChildren {
                    for child in nodes where child.isDirectory { child.prefetch() }
                }
            }
        }
    }
}

struct FileSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @State private var root: FileNode?
    @State private var selectedPath: String?

    /// Mirror the left sidebar's own style switch: when the Sidebar font is
    /// "Terminal Style" the tree renders monospaced with `▾/▸` and trailing
    /// slashes (an `ls`/`tree` look); otherwise it's a Finder-style list with
    /// the system font and real file icons.
    private var terminalStyle: Bool { appearanceStore.sidebarFont == .matchTerminal }
    private var accent: Color { Color(nsColor: sessionStore.terminalAccentColor) }
    private var selection: Color { Color(nsColor: sessionStore.terminalSelectionColor) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: rebuildRoot)
        .onChange(of: sessionStore.fileSidebarRoot) { _ in rebuildRoot() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if terminalStyle {
                Text("▾").font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
            } else {
                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(accent)
            }
            Text(terminalStyle ? displayName + "/" : displayName)
                .font(terminalStyle
                    ? .system(size: 11, weight: .semibold, design: .monospaced)
                    : .system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(sessionStore.fileSidebarRoot ?? "")
            Spacer(minLength: 4)
            Button {
                sessionStore.refreshFileSidebarRoot()
                root?.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.top, 34) // clear the transparent titlebar band (fullSizeContentView)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let root, root.children?.isEmpty == false || root.isLoading {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: terminalStyle ? 0 : 1) {
                    ForEach(root.children ?? []) { node in
                        FileNodeRow(
                            node: node,
                            depth: 0,
                            terminalStyle: terminalStyle,
                            accent: accent,
                            selection: selection,
                            selectedPath: $selectedPath
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, terminalStyle ? 0 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: sessionStore.fileSidebarRoot == nil ? "questionmark.folder" : "folder")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text(sessionStore.fileSidebarRoot == nil ? "No working directory" : "Empty folder")
                    .font(terminalStyle ? .system(size: 11, design: .monospaced) : .system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var displayName: String {
        guard let path = sessionStore.fileSidebarRoot else { return "—" }
        return (path as NSString).lastPathComponent
    }

    private func rebuildRoot() {
        selectedPath = nil
        guard let path = sessionStore.fileSidebarRoot else {
            root = nil
            return
        }
        let node = FileNode(url: URL(fileURLWithPath: path, isDirectory: true), isDirectory: true, showHidden: false)
        node.toggleExpansion() // false → true: expands and loads the root's children
        root = node
    }
}

/// One row plus, when expanded, its children indented beneath it. Recursive so
/// the whole visible subtree is a single view hierarchy; each `FileNodeRow`
/// observes only its own node.
private struct FileNodeRow: View {
    @ObservedObject var node: FileNode
    let depth: Int
    let terminalStyle: Bool
    let accent: Color
    let selection: Color
    @Binding var selectedPath: String?
    @EnvironmentObject private var editorPreferences: EditorPreferencesStore
    @State private var isHovering = false

    private var isSelected: Bool { selectedPath == node.url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: terminalStyle ? 0 : 1) {
            row
            if node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileNodeRow(
                        node: child,
                        depth: depth + 1,
                        terminalStyle: terminalStyle,
                        accent: accent,
                        selection: selection,
                        selectedPath: $selectedPath
                    )
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: terminalStyle ? 6 : 5) {
            disclosure
            if terminalStyle {
                // `ls`/`tree` look: no icon; directories are accent-colored with
                // a trailing slash, files plain.
                Text(node.isDirectory ? node.name + "/" : node.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(node.isDirectory ? accent : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                // Finder look: the real file icon and the system font.
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, terminalStyle ? 1.5 : 3)
        .padding(.trailing, 8)
        .padding(.leading, CGFloat(depth) * (terminalStyle ? 14 : 13) + (terminalStyle ? 10 : 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { open() }
        .onTapGesture {
            selectedPath = node.url.path
            if node.isDirectory { node.toggleExpansion() }
        }
        .contextMenu {
            if node.isDirectory {
                Button(node.isExpanded ? "Collapse" : "Expand") { node.toggleExpansion() }
                Button("Open in Editor") { EditorLaunchAdapter.openFile(node.url, choice: editorPreferences.choice) }
            } else {
                Button("Open in Editor") { open() }
                Button("Open with Default App") { NSWorkspace.shared.open(node.url) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        // Square, full-width highlight in terminal style (like the left
        // sidebar); an inset rounded pill otherwise.
        let fill = isSelected ? selection.opacity(0.55) : (isHovering ? Color.primary.opacity(0.07) : Color.clear)
        if terminalStyle {
            Rectangle().fill(fill)
        } else {
            RoundedRectangle(cornerRadius: 5).fill(fill)
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if node.isDirectory {
            if terminalStyle {
                Text(node.isExpanded ? "▾" : "▸")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: 10)
            }
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    private func open() {
        selectedPath = node.url.path
        if node.isDirectory {
            node.toggleExpansion()
        } else {
            EditorLaunchAdapter.openFile(node.url, choice: editorPreferences.choice)
        }
    }
}
