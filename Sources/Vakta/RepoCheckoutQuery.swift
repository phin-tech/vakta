//
//  RepoCheckoutQuery.swift
//  Vakta
//
//  Resolves a pane's working directory to its checkout with two short git
//  runs: the work-tree root and the current branch.

import Foundation

enum RepoCheckoutQuery {
    /// Pure: nil unless `topLevel` succeeded. `symbolic-ref --quiet` exits 1
    /// for a detached HEAD (no branch) but, unlike `rev-parse --abbrev-ref`,
    /// still names an unborn branch.
    static func interpret(topLevel: ProcessResult, branch: ProcessResult) -> RepoCheckout? {
        guard case .success(let rootOutput) = topLevel else { return nil }
        let root = droppingTerminatingNewline(rootOutput)
        guard !root.isEmpty else { return nil }

        var branchName: String?
        if case .success(let output) = branch {
            let name = droppingTerminatingNewline(output)
            branchName = name.isEmpty ? nil : name
        }
        return RepoCheckout(root: root, branch: branchName)
    }

    /// Blocks the calling thread (two short helper runs); call it off the
    /// main actor. `--no-optional-locks` keeps a background refresh from
    /// contending with the user's own git commands.
    static func query(directory: String, environment: [String: String], timeout: TimeInterval = 5) -> RepoCheckout? {
        func git(_ arguments: [String]) -> ProcessRawResult {
            BoundedProcessRunner.runRaw(
                executable: "/usr/bin/env",
                arguments: ["git", "--no-optional-locks", "-C", directory] + arguments,
                environment: environment,
                timeout: timeout,
                isCancelled: { false }
            )
        }
        let topLevel = ProcessResultInterpreter.interpret(git(["rev-parse", "--show-toplevel"]))
        guard case .success = topLevel else { return nil }
        let branch = ProcessResultInterpreter.interpret(git(["symbolic-ref", "--quiet", "--short", "HEAD"]))
        return interpret(topLevel: topLevel, branch: branch)
    }

    /// Drops only the terminating newline: a directory or branch name may
    /// itself contain other whitespace.
    private static func droppingTerminatingNewline(_ output: String) -> String {
        output.hasSuffix("\n") ? String(output.dropLast()) : output
    }
}
