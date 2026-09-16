//
//  SessionDiscovery.swift
//  Vakta
//
//  Lists the multiplexer sessions that already exist on the server, so the
//  "New Session" menu can offer to *attach* one (your `default` herdr session,
//  anything you've named) instead of only creating fresh ones. Discovery is
//  on-demand — the sidebar shows only what you've opened, never the whole list.

import Foundation

enum SessionDiscovery {
    /// Existing session names on `target`'s server. Runs a short-lived query
    /// with the resolved PATH (so the tool is found under a `.app`'s minimal
    /// environment) plus `target.environment` (e.g. a custom
    /// `HERDR_SOCKET_PATH`), and `target.executable` -- never a hardcoded
    /// `"herdr"`/`"tmux"` literal, so an absolute/custom-named binary is
    /// honored.
    static func names(for target: MultiplexerTarget, path: String, isCancelled: @escaping () -> Bool = { false }) -> [String] {
        let output = ProcessRunner.run(
            target.discoveryArgv,
            path: path,
            environment: target.environment,
            isCancelled: isCancelled
        )
        switch target.backend {
        case .herdr: return parseHerdr(output)
        case .tmux: return parseLines(output)
        }
    }

    /// `herdr session list` prints a header row then one session per line;
    /// the first column is the name.
    private static func parseHerdr(_ output: String?) -> [String] {
        guard let output else { return [] }
        return output.split(separator: "\n").compactMap { line in
            guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            else { return nil }
            let name = String(first)
            return name == "name" ? nil : name // skip the header
        }
    }

    private static func parseLines(_ output: String?) -> [String] {
        guard let output else { return [] }
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
