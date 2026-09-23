//
//  FileSidebarChangesLoader.swift
//  Vakta
//
//  Runs the Changes-mode git query off the main actor and publishes the
//  latest result for the file sidebar. At most one query runs at a time:
//  requests that arrive meanwhile collapse into a single follow-up for the
//  latest root. A result is dropped only when the root it answers is no
//  longer the one requested -- a same-root result is still the freshest
//  answer available, so repeated refreshes can't starve the list.
//

import Foundation

struct GitChangesSnapshot: Equatable, Sendable {
    let root: String
    let outcome: GitChangesOutcome
    /// The rows to render, built with the snapshot (off the main actor in
    /// the loader) rather than on every view update.
    let tree: [GitChangeTreeNode]

    init(root: String, outcome: GitChangesOutcome) {
        self.root = root
        self.outcome = outcome
        if case .changes(let changes) = outcome {
            tree = GitChangeTree.build(changes)
        } else {
            tree = []
        }
    }
}

@MainActor
final class FileSidebarChangesLoader: ObservableObject {
    private struct Request: Sendable {
        let root: String
        let environment: [String: String]
    }

    /// The latest applied result; kept while a refresh of the same root is
    /// in flight so the list doesn't flash empty.
    @Published private(set) var snapshot: GitChangesSnapshot?

    private let query: @Sendable (_ root: String, _ environment: [String: String]) -> GitChangesOutcome
    private let runInBackground: (@escaping @Sendable () -> Void) -> Void
    /// The root the sidebar currently wants; nil once cleared.
    private var requestedRoot: String?
    private var isRunning = false
    /// The newest request that arrived while a query was running.
    private var owed: Request?

    init(
        query: @escaping @Sendable (_ root: String, _ environment: [String: String]) -> GitChangesOutcome = {
            GitStatusQuery.query(root: $0, environment: $1)
        },
        runInBackground: @escaping (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.global(qos: .utility).async(execute: $0)
        }
    ) {
        self.query = query
        self.runInBackground = runInBackground
    }

    /// Queries `root` with `environment` (git's PATH/HOME; nil root clears
    /// the list). Supersedes any earlier request.
    func load(root: String?, environment: [String: String] = [:]) {
        requestedRoot = root
        guard let root else {
            owed = nil
            snapshot = nil
            return
        }
        if snapshot?.root != root { snapshot = nil }
        let request = Request(root: root, environment: environment)
        if isRunning {
            owed = request
        } else {
            start(request)
        }
    }

    private func start(_ request: Request) {
        isRunning = true
        let query = self.query
        runInBackground { [weak self] in
            let snapshot = GitChangesSnapshot(root: request.root, outcome: query(request.root, request.environment))
            DispatchQueue.main.async { self?.finish(snapshot) }
        }
    }

    private func finish(_ result: GitChangesSnapshot) {
        isRunning = false
        if requestedRoot == result.root, snapshot != result {
            snapshot = result
        }
        if let next = owed {
            owed = nil
            start(next)
        }
    }
}
