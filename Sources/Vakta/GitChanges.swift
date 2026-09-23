//
//  GitChanges.swift
//  Vakta
//
//  The file sidebar's Changes mode: which files under the sidebar root have
//  git changes. Pure parsing/scoping/tree-building over
//  `git status --porcelain=v1 -z` output, plus `GitStatusQuery.query`, the
//  one shell entry point that runs git (off the main actor -- the caller
//  dispatches).
//

import Foundation

enum GitChangeKind: Equatable, Hashable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case conflicted
}

/// One changed file. `path` is relative to the repository root as git
/// reports it, or to the sidebar root after `GitChangeScope.scoped`.
struct GitChange: Equatable, Hashable, Sendable {
    let path: String
    let kind: GitChangeKind
}

enum GitStatusParser {
    private static let unmergedPairs: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    /// Parses `git status --porcelain=v1 -z`: NUL-terminated `XY PATH`
    /// records, where a rename or copy is followed by one extra record
    /// holding its source path. Ignored (`!!`) and malformed records are
    /// skipped without dropping the rest, as is a record whose path isn't
    /// UTF-8 (git passes filename bytes through untouched).
    static func parse(_ output: Data) -> [GitChange] {
        var records = output.split(separator: 0, omittingEmptySubsequences: true)[...]
        var changes: [GitChange] = []
        while let record = records.popFirst() {
            guard record.count > 3 else { continue }
            let x = Character(Unicode.Scalar(record[record.startIndex]))
            let y = Character(Unicode.Scalar(record[record.startIndex + 1]))
            if x == "R" || x == "C" { _ = records.popFirst() }
            guard let path = String(data: Data(record.dropFirst(3)), encoding: .utf8) else { continue }
            let status = String([x, y])

            let kind: GitChangeKind
            if status == "!!" { continue }
            if status == "??" {
                kind = .untracked
            } else if unmergedPairs.contains(status) {
                kind = .conflicted
            } else if x == "D" || y == "D" {
                // Checked before added/renamed: AD and RD are files staged
                // and then removed from the worktree -- nothing to open.
                kind = .deleted
            } else if x == "R" {
                kind = .renamed
            } else if x == "A" || x == "C" {
                kind = .added
            } else {
                kind = .modified
            }
            changes.append(GitChange(path: path, kind: kind))
        }
        return changes
    }

    static func parse(_ output: String) -> [GitChange] {
        parse(Data(output.utf8))
    }
}

enum GitChangeScope {
    /// Keeps the changes under `prefix` (the sidebar root's path inside the
    /// repository, as `git rev-parse --show-prefix` prints it; empty at the
    /// repository root) and makes their paths relative to it.
    static func scoped(_ changes: [GitChange], toPrefix prefix: String) -> [GitChange] {
        guard !prefix.isEmpty else { return changes }
        let directory = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return changes.compactMap { change in
            guard change.path.hasPrefix(directory) else { return nil }
            return GitChange(path: String(change.path.dropFirst(directory.count)), kind: change.kind)
        }
    }
}

/// One row of the Changes tree: a directory holding changed files, or a
/// changed file. `path` is relative to the sidebar root and unique, so it
/// doubles as the row identity.
struct GitChangeTreeNode: Equatable, Identifiable, Sendable {
    enum Content: Equatable, Sendable {
        case directory([GitChangeTreeNode])
        case file(GitChangeKind)
    }

    let name: String
    let path: String
    let content: Content

    var id: String { path }
}

struct GitChangeTreeRow: Equatable, Identifiable {
    let node: GitChangeTreeNode
    let depth: Int

    var id: String { node.path }
}

enum GitChangeTree {
    /// Nests `changes` under their directories. Same order as the Files
    /// tree (directories first, case-insensitive alphabetical), but dotfiles
    /// are shown -- a changed `.github/` file matters as much as any other.
    static func build(_ changes: [GitChange]) -> [GitChangeTreeNode] {
        build(changes.map { (components: components(of: $0.path), kind: $0.kind) }, parent: "")
    }

    /// Path components, with an untracked directory's trailing slash kept on
    /// its last component (`build/` → `["build/"]`) so it stays one leaf row
    /// rather than an empty expandable folder.
    private static func components(of path: String) -> [String] {
        var parts = path.split(separator: "/").map(String.init)
        if path.hasSuffix("/"), !parts.isEmpty { parts[parts.count - 1] += "/" }
        return parts
    }

    private static func build(_ entries: [(components: [String], kind: GitChangeKind)], parent: String) -> [GitChangeTreeNode] {
        var files: [GitChangeTreeNode] = []
        var directories: [String: [(components: [String], kind: GitChangeKind)]] = [:]
        for entry in entries {
            guard let first = entry.components.first else { continue }
            let path = parent.isEmpty ? first : parent + "/" + first
            if entry.components.count == 1 {
                files.append(GitChangeTreeNode(name: first, path: path, content: .file(entry.kind)))
            } else {
                directories[first, default: []].append((Array(entry.components.dropFirst()), entry.kind))
            }
        }
        let directoryNodes = directories.map { name, children in
            let path = parent.isEmpty ? name : parent + "/" + name
            return GitChangeTreeNode(name: name, path: path, content: .directory(build(children, parent: path)))
        }
        return sortedByName(directoryNodes) + sortedByName(files)
    }

    private static func sortedByName(_ nodes: [GitChangeTreeNode]) -> [GitChangeTreeNode] {
        nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The rows to draw, depth-first, skipping the contents of every
    /// directory whose path is in `collapsed`. Flat so the view can render
    /// one lazy list instead of eagerly nesting each expanded directory.
    static func visibleRows(_ nodes: [GitChangeTreeNode], collapsed: Set<String>, depth: Int = 0) -> [GitChangeTreeRow] {
        nodes.flatMap { node -> [GitChangeTreeRow] in
            let row = GitChangeTreeRow(node: node, depth: depth)
            guard case .directory(let children) = node.content, !collapsed.contains(node.path) else { return [row] }
            return [row] + visibleRows(children, collapsed: collapsed, depth: depth + 1)
        }
    }

    /// Every directory's path in `nodes`, depth-first -- the rows the view
    /// starts expanded.
    static func directoryPaths(in nodes: [GitChangeTreeNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            guard case .directory(let children) = node.content else { return [] }
            return [node.path] + directoryPaths(in: children)
        }
    }
}

enum GitChangesOutcome: Equatable, Sendable {
    case changes([GitChange])
    case notARepository
    /// git is missing, failed, or timed out.
    case unavailable
}

enum GitStatusQuery {
    /// git's exit status when the directory is not inside a work tree.
    private static let notARepositoryExitCode: Int32 = 128

    /// Classifies the two helper runs: `git rev-parse --show-prefix` (the
    /// root's path inside the repository), then -- only if that succeeded --
    /// `git status --porcelain=v1 -z` limited to the root. The status output
    /// stays raw bytes so one non-UTF-8 filename can't hide every change.
    static func interpret(prefix: ProcessResult, status: ProcessRawResult?) -> GitChangesOutcome {
        guard case .success(let prefixOutput) = prefix else {
            if case .nonZeroExit(notARepositoryExitCode) = prefix { return .notARepository }
            return .unavailable
        }
        guard let status, !status.launchFailed, !status.cancelled, !status.timedOut, status.exitCode == 0 else {
            return .unavailable
        }
        // Drop only the terminating newline: a directory may itself be named
        // with a leading or embedded newline.
        let prefixPath = prefixOutput.hasSuffix("\n") ? String(prefixOutput.dropLast()) : prefixOutput
        let changes = GitChangeScope.scoped(GitStatusParser.parse(status.stdout), toPrefix: prefixPath)
        return .changes(changes.filter(isShown))
    }

    /// The sidebar lists modified and new files only: a deleted file has
    /// nothing to open, and an untracked directory (`build/`, anything not
    /// yet ignored) is one opaque row standing for arbitrarily many files.
    private static func isShown(_ change: GitChange) -> Bool {
        change.kind != .deleted && !change.path.hasSuffix("/")
    }

    /// Runs git in `root`. Blocks the calling thread (two short helper
    /// runs); call it off the main actor.
    ///
    /// `--untracked-files=normal` is explicit so the user's
    /// `status.showUntrackedFiles` can neither hide new files (`no`) nor
    /// expand a new directory into every file inside it (`all`).
    /// `--no-optional-locks` keeps this background refresh from taking
    /// `index.lock` and rewriting the index, which would contend with the
    /// user's own git commands in the terminal.
    static func query(root: String, environment: [String: String]) -> GitChangesOutcome {
        func git(_ arguments: [String]) -> ProcessRawResult {
            BoundedProcessRunner.runRaw(
                executable: "/usr/bin/env",
                arguments: ["git", "--no-optional-locks", "-C", root] + arguments,
                environment: environment,
                timeout: 5,
                isCancelled: { false }
            )
        }
        let prefix = ProcessResultInterpreter.interpret(git(["rev-parse", "--show-prefix"]))
        guard case .success = prefix else { return interpret(prefix: prefix, status: nil) }
        let status = git(["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", "."])
        return interpret(prefix: prefix, status: status)
    }
}
