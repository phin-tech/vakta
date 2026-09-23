//
//  RepoCheckoutQuery.swift
//  Vakta
//
//  Resolves a pane's working directory to its checkout with three short git
//  runs: the work-tree root, the current branch, and the remote/branch
//  config that decides which repository and head owner a PR lookup uses.

import Foundation

enum RepoCheckoutQuery {
    /// Remote URLs plus every setting that picks the branch's push remote.
    static let configPattern = #"^(remote\..*\.url|remote\.pushdefault|branch\..*\.(remote|pushremote))$"#

    /// Pure: nil unless `topLevel` succeeded. `symbolic-ref --quiet` exits 1
    /// for a detached HEAD (no branch) but, unlike `rev-parse --abbrev-ref`,
    /// still names an unborn branch. `config --get-regexp` exits 1 when
    /// nothing matches, which is simply no remotes.
    static func interpret(topLevel: ProcessResult, branch: ProcessResult, config: ProcessRawResult) -> RepoCheckout? {
        guard case .success(let rootOutput) = topLevel else { return nil }
        let root = droppingTerminatingNewline(rootOutput)
        guard !root.isEmpty else { return nil }

        var branchName: String?
        if case .success(let output) = branch {
            let name = droppingTerminatingNewline(output)
            branchName = name.isEmpty ? nil : name
        }
        let configuration = config.exitCode == 0 ? RepoCheckout.parseConfig(config.stdout) : [:]
        return RepoCheckout(root: root, branch: branchName, config: configuration)
    }

    /// Blocks the calling thread (three short helper runs); call it off the
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
        let config = git(["config", "-z", "--get-regexp", configPattern])
        return interpret(topLevel: topLevel, branch: branch, config: config)
    }

    /// Drops only the terminating newline: a directory or branch name may
    /// itself contain other whitespace.
    private static func droppingTerminatingNewline(_ output: String) -> String {
        output.hasSuffix("\n") ? String(output.dropLast()) : output
    }
}
