//
//  HerdrSidebarRows.swift
//  Vakta
//
//  Pure model for herdr's sidebar `rows` (a list of token rows under
//  `[ui.sidebar.agents]` / `[ui.sidebar.spaces]`). Only plain string tokens are
//  editable here; a row containing a styled token (`{ token = ..., bold = ... }`)
//  is not parsed, so the GUI leaves that value read-only rather than drop the
//  styling. Tokens are validated against herdr's documented built-ins plus
//  `$name` metadata tokens.

import Foundation

enum HerdrSidebarRows {
    enum Kind {
        case agents, spaces

        var path: String {
            switch self {
            case .agents: return "ui.sidebar.agents.rows"
            case .spaces: return "ui.sidebar.spaces.rows"
            }
        }

        var builtinTokens: [String] {
            switch self {
            case .agents:
                return ["state_icon", "state_text", "machine", "workspace", "tab", "pane", "agent",
                        "terminal_title", "terminal_title_stripped"]
            case .spaces:
                return ["state_icon", "state_text", "workspace", "branch", "git_status"]
            }
        }
    }

    static let maxRows = 16
    static let maxTokensPerRow = 16

    static func defaultRows(for kind: Kind) -> [[String]] {
        switch kind {
        case .agents: return [["state_icon", "machine", "workspace", "tab"], ["agent"]]
        case .spaces: return [["state_icon", "workspace"], ["branch", "git_status"]]
        }
    }

    /// Rows from the TOML source of the array, or nil if it holds anything but
    /// plain string tokens (or isn't well-formed).
    static func parse(source: String) -> [[String]]? {
        var scanner = Scanner(chars: Array(source))
        guard scanner.consume("[") else { return nil }
        var rows: [[String]] = []
        while true {
            scanner.skipNoise()
            if scanner.consume("]") { break }
            guard scanner.consume("[") else { return nil }
            var tokens: [String] = []
            while true {
                scanner.skipNoise()
                if scanner.consume("]") { break }
                guard let token = scanner.string() else { return nil }
                tokens.append(token)
            }
            rows.append(tokens)
        }
        scanner.skipNoise()
        return scanner.atEnd ? rows : nil
    }

    static func format(_ rows: [[String]]) -> String {
        let body = rows.map { row in
            "[" + row.map { HerdrConfigValue.string($0).sourceText }.joined(separator: ", ") + "]"
        }
        return "[" + body.joined(separator: ", ") + "]"
    }

    static func problems(in rows: [[String]], for kind: Kind) -> [String] {
        var found: [String] = []
        if rows.count > maxRows { found.append("At most \(maxRows) rows.") }
        for row in rows {
            if row.count > maxTokensPerRow { found.append("At most \(maxTokensPerRow) tokens per row.") }
            for token in row where !isValid(token, for: kind) {
                found.append("Unknown token “\(token)” for \(kind == .agents ? "agent" : "space") rows.")
            }
        }
        return found
    }

    /// `state_icon, workspace, tab` -> tokens; empty entries dropped.
    static func tokens(fromRowText text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func isValid(_ token: String, for kind: Kind) -> Bool {
        if kind.builtinTokens.contains(token) { return true }
        guard token.hasPrefix("$"), token.count > 1 else { return false }
        return token.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private struct Scanner {
        let chars: [Character]
        var index = 0

        var atEnd: Bool { index >= chars.count }

        mutating func skipNoise() {
            while index < chars.count {
                let character = chars[index]
                if character.isWhitespace || character == "," {
                    index += 1
                } else if character == "#" {
                    while index < chars.count, chars[index] != "\n" { index += 1 }
                } else {
                    return
                }
            }
        }

        mutating func consume(_ character: Character) -> Bool {
            skipNoise()
            guard index < chars.count, chars[index] == character else { return false }
            index += 1
            return true
        }

        mutating func string() -> String? {
            skipNoise()
            guard index < chars.count, chars[index] == "\"" else { return nil }
            index += 1
            var result = ""
            while index < chars.count {
                let character = chars[index]
                index += 1
                if character == "\"" { return result }
                if character == "\\" {
                    guard index < chars.count else { return nil }
                    let escaped = chars[index]
                    index += 1
                    switch escaped {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    default: return nil
                    }
                } else {
                    result.append(character)
                }
            }
            return nil
        }
    }
}
