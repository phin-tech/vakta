//
//  FileSidebarView.swift
//  Vakta
//
//  The right-hand file sidebar: a lazy, expandable tree of the selected
//  session's focused-pane working directory (`SessionStore.fileSidebarRoot`).
//  SwiftUI so it matches the left sidebar's chrome; lazy in both senses --
//  `FileTreeModel` reads a directory (off the main thread) only when it is
//  expanded or prefetched one level ahead, and the rows render as one flat
//  lazy list (`FileTreeLayout.visibleRows`), so only on-screen rows are built. Read-only: double-click opens a file in its default app; the context
//  menu reveals in Finder or opens.
//
//  The header's Files/Changes toggle (`FileSidebarPreferencesStore.mode`)
//  swaps the tree for only the files git reports as changed under the same
//  root (`GitChangeTree`), refreshed by `FileSidebarChangesLoader` whenever
//  the root is re-resolved.
//

import AppKit
import SwiftUI

struct FileSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var preferences: FileSidebarPreferencesStore
    @StateObject private var changesLoader = FileSidebarChangesLoader()
    @StateObject private var fileTree = FileTreeModel()
    @State private var selectedPath: String?
    /// Changes-view directories the user collapsed (all start expanded).
    @State private var collapsedChangePaths: Set<String> = []

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
        .onAppear {
            rebuildRoot()
            loadChanges()
        }
        // Root changes re-query through `fileSidebarRefreshed`, which
        // `SessionStore` sends after every root resolution (including a move
        // to no root); loading here as well would run git twice.
        .onChange(of: sessionStore.fileSidebarRoot) { _ in
            rebuildRoot()
            collapsedChangePaths = []
        }
        .onChange(of: preferences.mode) { _ in loadChanges() }
        .onReceive(sessionStore.fileSidebarRefreshed) { loadChanges() }
    }

    /// Re-runs git for the current root while Changes is showing; the Files
    /// tree never pays for it.
    private func loadChanges() {
        guard preferences.mode == .changes else { return }
        changesLoader.load(
            root: sessionStore.fileSidebarRoot,
            environment: ["PATH": sessionStore.resolvedPATH, "HOME": NSHomeDirectory()]
        )
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
            modeToggle
            Button {
                sessionStore.refreshFileSidebarRoot()
                fileTree.reload()
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

    /// Files ↔ Changes. Two small icon buttons rather than a `Picker` so it
    /// fits the header row and takes the terminal accent.
    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeButton(.files, symbol: "folder", help: "All files")
            modeButton(.changes, symbol: "plusminus", help: "Git changes only")
        }
        .padding(1)
        .background(
            RoundedRectangle(cornerRadius: terminalStyle ? 0 : 5).fill(Color.primary.opacity(0.06))
        )
    }

    private func modeButton(_ mode: FileSidebarMode, symbol: String, help: String) -> some View {
        let isOn = preferences.mode == mode
        return Button {
            preferences.mode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 16)
                .foregroundStyle(isOn ? accent : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: terminalStyle ? 0 : 4)
                        .fill(isOn ? selection.opacity(0.55) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        if preferences.mode == .changes {
            changesContent
        } else {
            filesContent
        }
    }

    @ViewBuilder
    private var changesContent: some View {
        if let rootPath = sessionStore.fileSidebarRoot,
           let snapshot = changesLoader.snapshot, snapshot.root == rootPath,
           !snapshot.tree.isEmpty {
            ScrollView {
                // One flat lazy list: only rows on screen are built, however
                // many changes a directory holds.
                LazyVStack(alignment: .leading, spacing: terminalStyle ? 0 : 1) {
                    ForEach(GitChangeTree.visibleRows(snapshot.tree, collapsed: collapsedChangePaths)) { row in
                        ChangeNodeRow(
                            node: row.node,
                            root: URL(fileURLWithPath: rootPath, isDirectory: true),
                            depth: row.depth,
                            terminalStyle: terminalStyle,
                            accent: accent,
                            selection: selection,
                            collapsedPaths: $collapsedChangePaths,
                            selectedPath: $selectedPath
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, terminalStyle ? 0 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            placeholder(symbol: changesPlaceholder.symbol, text: changesPlaceholder.text)
        }
    }

    private var changesPlaceholder: (symbol: String, text: String) {
        guard let rootPath = sessionStore.fileSidebarRoot else { return ("questionmark.folder", "No working directory") }
        guard let snapshot = changesLoader.snapshot, snapshot.root == rootPath else { return ("hourglass", "Checking git status…") }
        switch snapshot.outcome {
        case .changes: return ("checkmark.circle", "No changes")
        case .notARepository: return ("folder", "Not a git repository")
        case .unavailable: return ("exclamationmark.triangle", "git status unavailable")
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(terminalStyle ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var filesContent: some View {
        let rows = fileTree.rows
        if !rows.isEmpty || (sessionStore.fileSidebarRoot != nil && !fileTree.isRootLoaded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: terminalStyle ? 0 : 1) {
                    ForEach(rows) { row in
                        FileNodeRow(
                            row: row,
                            tree: fileTree,
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
            placeholder(
                symbol: sessionStore.fileSidebarRoot == nil ? "questionmark.folder" : "folder",
                text: sessionStore.fileSidebarRoot == nil ? "No working directory" : "Empty folder"
            )
        }
    }

    private var displayName: String {
        guard let path = sessionStore.fileSidebarRoot else { return "—" }
        return (path as NSString).lastPathComponent
    }

    private func rebuildRoot() {
        selectedPath = nil
        fileTree.setRoot(sessionStore.fileSidebarRoot)
    }
}

/// One row of the Files tree. Not recursive: `FileTreeModel.rows` already
/// lists an expanded directory's children beneath it, at their depth.
private struct FileNodeRow: View {
    let row: FileTreeRow
    @ObservedObject var tree: FileTreeModel
    let terminalStyle: Bool
    let accent: Color
    let selection: Color
    @Binding var selectedPath: String?
    @EnvironmentObject private var editorPreferences: EditorPreferencesStore
    @State private var isHovering = false

    private var url: URL { URL(fileURLWithPath: row.path, isDirectory: row.isDirectory) }
    private var isSelected: Bool { selectedPath == row.path }

    var body: some View {
        rowContent
    }

    private var rowContent: some View {
        HStack(spacing: terminalStyle ? 6 : 5) {
            disclosure
            if terminalStyle {
                // `ls`/`tree` look: no icon; directories are accent-colored with
                // a trailing slash, files plain.
                Text(row.isDirectory ? row.name + "/" : row.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(row.isDirectory ? accent : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                // Finder look: the real file icon and the system font.
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(row.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, terminalStyle ? 1.5 : 3)
        .padding(.trailing, 8)
        .padding(.leading, CGFloat(row.depth) * (terminalStyle ? 14 : 13) + (terminalStyle ? 10 : 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { handleClick() }
        .contextMenu {
            if row.isDirectory {
                Button(row.isExpanded ? "Collapse" : "Expand") { tree.toggle(row.path) }
                Button("Open in Editor") { EditorLaunchAdapter.openFile(url, choice: editorPreferences.choice) }
            } else {
                Button("Open in Editor") { open() }
                Button("Open with Default App") { NSWorkspace.shared.open(url) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
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
        if row.isDirectory {
            if terminalStyle {
                Text(row.isExpanded ? "▾" : "▸")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 10)
            }
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    private func handleClick() {
        selectedPath = row.path
        let clickCount = NSApp.currentEvent?.clickCount ?? 1
        switch FileRowClickPlanner.action(clickCount: clickCount, isDirectory: row.isDirectory, canOpen: true) {
        case .select: break
        case .toggleExpansion: tree.toggle(row.path)
        case .open: open()
        }
    }

    private func open() {
        selectedPath = row.path
        if row.isDirectory {
            tree.toggle(row.path)
        } else {
            EditorLaunchAdapter.openFile(url, choice: editorPreferences.choice)
        }
    }
}

/// One row of the Changes tree. Directories start expanded -- the point of the
/// view is to see every changed file -- and collapse per row via
/// `collapsedPaths`, which `GitChangeTree.visibleRows` reads to flatten the
/// list.
private struct ChangeNodeRow: View {
    let node: GitChangeTreeNode
    let root: URL
    let depth: Int
    let terminalStyle: Bool
    let accent: Color
    let selection: Color
    @Binding var collapsedPaths: Set<String>
    @Binding var selectedPath: String?
    @EnvironmentObject private var editorPreferences: EditorPreferencesStore
    @State private var isHovering = false

    private var isCollapsed: Bool { collapsedPaths.contains(node.path) }

    private func toggleCollapsed() {
        if collapsedPaths.remove(node.path) == nil { collapsedPaths.insert(node.path) }
    }

    private var url: URL { root.appendingPathComponent(node.path, isDirectory: isDirectory) }
    private var isSelected: Bool { selectedPath == url.path }

    private var isDirectory: Bool {
        if case .directory = node.content { return true }
        return false
    }

    private var kind: GitChangeKind? {
        if case .file(let kind) = node.content { return kind }
        return nil
    }

    var body: some View {
        HStack(spacing: terminalStyle ? 6 : 5) {
            disclosure
            if terminalStyle {
                Text(isDirectory ? node.name + "/" : node.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isDirectory ? accent : nameColor)
                    .strikethrough(kind == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(nsImage: isDirectory
                    ? NSWorkspace.shared.icon(for: .folder)
                    : NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundStyle(nameColor)
                    .strikethrough(kind == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let kind {
                Text(Self.badge(kind))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.color(kind))
                    .help(Self.description(kind))
                    .accessibilityLabel(Self.description(kind))
            }
        }
        .padding(.vertical, terminalStyle ? 1.5 : 3)
        .padding(.trailing, 8)
        .padding(.leading, CGFloat(depth) * (terminalStyle ? 14 : 13) + (terminalStyle ? 10 : 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { handleClick() }
        .contextMenu {
            if isDirectory {
                Button(isCollapsed ? "Expand" : "Collapse") { toggleCollapsed() }
                Button("Open in Editor") { EditorLaunchAdapter.openFile(url, choice: editorPreferences.choice) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else if kind != .deleted {
                Button("Open in Editor") { open() }
                Button("Open with Default App") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private var nameColor: Color {
        kind == .deleted ? Color.secondary : Color.primary
    }

    @ViewBuilder
    private var rowBackground: some View {
        let fill = isSelected ? selection.opacity(0.55) : (isHovering ? Color.primary.opacity(0.07) : Color.clear)
        if terminalStyle {
            Rectangle().fill(fill)
        } else {
            RoundedRectangle(cornerRadius: 5).fill(fill)
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if isDirectory {
            if terminalStyle {
                Text(isCollapsed ? "▸" : "▾")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
            }
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    private func handleClick() {
        selectedPath = url.path
        let clickCount = NSApp.currentEvent?.clickCount ?? 1
        switch FileRowClickPlanner.action(clickCount: clickCount, isDirectory: isDirectory, canOpen: kind != .deleted) {
        case .select: break
        case .toggleExpansion: toggleCollapsed()
        case .open: open()
        }
    }

    private func open() {
        selectedPath = url.path
        if isDirectory {
            toggleCollapsed()
        } else if kind != .deleted {
            EditorLaunchAdapter.openFile(url, choice: editorPreferences.choice)
        }
    }

    /// VS Code's letters: U is untracked, ! a merge conflict.
    private static func badge(_ kind: GitChangeKind) -> String {
        switch kind {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    private static func description(_ kind: GitChangeKind) -> String {
        switch kind {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .conflicted: return "Merge conflict"
        }
    }

    private static func color(_ kind: GitChangeKind) -> Color {
        switch kind {
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted, .conflicted: return .red
        case .renamed: return .blue
        }
    }
}
