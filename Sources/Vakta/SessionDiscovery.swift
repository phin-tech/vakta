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
    /// Existing session names for the multiplexer a profile drives. Empty for
    /// profiles that aren't a known multiplexer, or when nothing is running.
    /// Runs a short-lived query with the resolved PATH so the tool is found
    /// under a `.app`'s minimal environment.
    static func names(for profile: Profile, path: String) -> [String] {
        switch multiplexer(of: profile) {
        case .herdr:
            return parseHerdr(ProcessRunner.run(["herdr", "session", "list"], path: path))
        case .tmux:
            return parseLines(ProcessRunner.run(["tmux", "list-sessions", "-F", "#{session_name}"], path: path))
        case .none:
            return []
        }
    }

    /// Whether a profile drives a multiplexer Vakta knows how to enumerate.
    static func supportsDiscovery(_ profile: Profile) -> Bool {
        multiplexer(of: profile) != nil
    }

    private enum Multiplexer { case herdr, tmux }

    private static func multiplexer(of profile: Profile) -> Multiplexer? {
        switch (profile.command as NSString).lastPathComponent {
        case "herdr": return .herdr
        case "tmux": return .tmux
        default: return nil
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
