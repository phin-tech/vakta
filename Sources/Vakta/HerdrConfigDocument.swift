//
//  HerdrConfigDocument.swift
//  Vakta
//
//  Pure, value-typed view of herdr's config.toml that patches individual
//  values in place instead of parsing and re-serializing the file, so
//  comments, ordering, CRLF endings, unknown keys, and `[[array]]` tables the
//  editor does not own survive a save byte-for-byte. It is deliberately not a
//  TOML parser: it only locates `key = value` spans. Anything it cannot
//  delimit is skipped (never guessed at). See docs/herdr-config-gui-plan.md.

import Foundation

/// A config value as far as the editor understands it. `.raw` is the source
/// text of anything else (multi-line arrays, inline tables, multi-line
/// strings, floats, dates): displayed read-only, never rewritten by guesswork.
enum HerdrConfigValue: Equatable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case raw(String)

    var sourceText: String {
        switch self {
        case .string(let value):
            var escaped = ""
            for character in value {
                switch character {
                case "\\": escaped += "\\\\"
                case "\"": escaped += "\\\""
                case "\n": escaped += "\\n"
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                default: escaped.append(character)
                }
            }
            return "\"\(escaped)\""
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .raw(let text): return text
        }
    }
}

/// One `[[path]]` block's fields (single-line/scalar values as understood by
/// the editor; anything else surfaces as `.raw`).
struct HerdrConfigArrayEntry: Equatable {
    let fields: [String: HerdrConfigValue]
}

struct HerdrConfigDocument: Equatable {
    let text: String

    private let lines: [Line]
    private let eol: String
    private let entries: [Entry]
    private let tables: [Table]
    private let blocks: [ArrayBlock]

    init(text: String) {
        self.text = text
        let lines = Self.splitLines(text)
        self.lines = lines
        eol = text.contains("\r\n") ? "\r\n" : "\n"
        let parsed = Self.parse(lines)
        entries = parsed.entries
        tables = parsed.tables
        blocks = parsed.blocks
    }

    static func == (lhs: HerdrConfigDocument, rhs: HerdrConfigDocument) -> Bool {
        lhs.text == rhs.text
    }

    // MARK: - Reading

    func value(at path: String) -> HerdrConfigValue? {
        guard let entry = entries.first(where: { $0.path == path }) else { return nil }
        return value(of: entry)
    }

    private func value(of entry: Entry) -> HerdrConfigValue {
        let source = spanText(of: entry)
        if entry.startLine != entry.endLine { return .raw(source) }
        if source.hasPrefix("\"\"\"") || source.hasPrefix("'''") { return .raw(source) }
        if source.hasPrefix("\""), source.hasSuffix("\""), source.count >= 2 {
            return .string(Self.unescape(String(source.dropFirst().dropLast())))
        }
        if source.hasPrefix("'"), source.hasSuffix("'"), source.count >= 2 {
            return .string(String(source.dropFirst().dropLast()))
        }
        if source == "true" { return .bool(true) }
        if source == "false" { return .bool(false) }
        if let integer = Int(source) { return .integer(integer) }
        return .raw(source)
    }

    /// Paths of every key in the file not present in `known`, in file order.
    func keyPaths(excluding known: Set<String>) -> [String] {
        entries.map(\.path).filter { !known.contains($0) }
    }

    // MARK: - Patching

    func setting(_ path: String, to value: HerdrConfigValue) -> HerdrConfigDocument {
        var lines = self.lines
        if let entry = entries.first(where: { $0.path == path }) {
            return replacing(entry, with: value)
        }

        let components = path.split(separator: ".").map(String.init)
        guard let key = components.last else { return self }
        let tablePath = components.dropLast().joined(separator: ".")
        let newLine = "\(key) = \(value.sourceText)"

        if let table = tables.first(where: { $0.path == tablePath && !$0.isArray }) {
            return inserting(newLine, after: table.lastLine)
        } else {
            if let last = lines.indices.last {
                if lines[last].terminator.isEmpty { lines[last].terminator = eol }
                if !lines[last].content.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(Line(content: "", terminator: eol))
                }
            }
            lines.append(Line(content: "[\(tablePath)]", terminator: eol))
            lines.append(Line(content: newLine, terminator: eol))
        }
        return HerdrConfigDocument(text: Self.join(lines))
    }

    func unsetting(_ path: String) -> HerdrConfigDocument {
        guard let entry = entries.first(where: { $0.path == path }) else { return self }
        return removing(entry)
    }

    // MARK: - Array tables (`[[path]]`)

    func arrayTableEntries(_ path: String) -> [HerdrConfigArrayEntry] {
        blocks.filter { $0.path == path }.map { block in
            var fields: [String: HerdrConfigValue] = [:]
            for entry in block.entries where fields[entry.path] == nil { fields[entry.path] = value(of: entry) }
            return HerdrConfigArrayEntry(fields: fields)
        }
    }

    func appendingArrayTable(_ path: String, fields: [(String, HerdrConfigValue)]) -> HerdrConfigDocument {
        var lines = self.lines
        if let last = lines.indices.last {
            if lines[last].terminator.isEmpty { lines[last].terminator = eol }
            if !lines[last].content.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(Line(content: "", terminator: eol))
            }
        }
        lines.append(Line(content: "[[\(path)]]", terminator: eol))
        for (key, value) in fields {
            lines.append(Line(content: "\(key) = \(value.sourceText)", terminator: eol))
        }
        return HerdrConfigDocument(text: Self.join(lines))
    }

    func removingArrayTable(_ path: String, at index: Int) -> HerdrConfigDocument {
        guard let block = block(path, index) else { return self }
        var lines = self.lines
        let removedLastTerminator = lines[block.lastLine].terminator
        lines.removeSubrange(block.headerLine...block.lastLine)
        let at = block.headerLine
        // Drop the separator blank that only existed to set this block apart.
        if at > 0, lines[at - 1].content.trimmingCharacters(in: .whitespaces).isEmpty,
           at == lines.count || lines[at].content.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: at - 1)
        } else if removedLastTerminator.isEmpty, at > 0, at == lines.count {
            lines[at - 1].terminator = ""
        }
        return HerdrConfigDocument(text: Self.join(lines))
    }

    func settingInArrayTable(_ path: String, at index: Int, key: String, to value: HerdrConfigValue) -> HerdrConfigDocument {
        guard let block = block(path, index) else { return self }
        if let entry = block.entries.first(where: { $0.path == key }) {
            return replacing(entry, with: value)
        }
        return inserting("\(key) = \(value.sourceText)", after: block.lastLine)
    }

    func unsettingInArrayTable(_ path: String, at index: Int, key: String) -> HerdrConfigDocument {
        guard let entry = block(path, index)?.entries.first(where: { $0.path == key }) else { return self }
        return removing(entry)
    }

    private func block(_ path: String, _ index: Int) -> ArrayBlock? {
        let matching = blocks.filter { $0.path == path }
        return matching.indices.contains(index) ? matching[index] : nil
    }

    private func replacing(_ entry: Entry, with value: HerdrConfigValue) -> HerdrConfigDocument {
        var lines = self.lines
        let startChars = Array(lines[entry.startLine].content)
        let endChars = Array(lines[entry.endLine].content)
        let content = String(startChars[0..<entry.startCol]) + value.sourceText + String(endChars[entry.endCol...])
        let terminator = lines[entry.endLine].terminator
        lines.replaceSubrange(entry.startLine...entry.endLine, with: [Line(content: content, terminator: terminator)])
        return HerdrConfigDocument(text: Self.join(lines))
    }

    private func inserting(_ newLine: String, after lastLine: Int) -> HerdrConfigDocument {
        var lines = self.lines
        let index = lastLine + 1
        if index >= lines.count, let last = lines.indices.last, lines[last].terminator.isEmpty {
            lines[last].terminator = eol
        }
        lines.insert(Line(content: newLine, terminator: eol), at: min(index, lines.count))
        return HerdrConfigDocument(text: Self.join(lines))
    }

    private func removing(_ entry: Entry) -> HerdrConfigDocument {
        var lines = self.lines
        let removedLastTerminator = lines[entry.endLine].terminator
        lines.removeSubrange(entry.startLine...entry.endLine)
        // Removing an unterminated final line must not leave a newline the
        // original file did not have.
        if removedLastTerminator.isEmpty, entry.startLine > 0, entry.startLine == lines.count {
            lines[entry.startLine - 1].terminator = ""
        }
        return HerdrConfigDocument(text: Self.join(lines))
    }

    // MARK: - Line model

    fileprivate struct Line {
        var content: String
        var terminator: String
    }

    fileprivate struct Entry {
        let path: String
        let startLine: Int
        let startCol: Int
        let endLine: Int
        let endCol: Int
    }

    fileprivate struct ArrayBlock {
        let path: String
        let headerLine: Int
        var lastLine: Int
        var entries: [Entry]
    }

    fileprivate struct Table {
        let path: String
        let isArray: Bool
        let headerLine: Int?
        var lastLine: Int
    }

    private func spanText(of entry: Entry) -> String {
        if entry.startLine == entry.endLine {
            let chars = Array(lines[entry.startLine].content)
            return String(chars[entry.startCol..<entry.endCol])
        }
        var parts: [String] = []
        for index in entry.startLine...entry.endLine {
            let chars = Array(lines[index].content)
            let from = index == entry.startLine ? entry.startCol : 0
            let to = index == entry.endLine ? entry.endCol : chars.count
            parts.append(String(chars[from..<to]))
        }
        return parts.joined(separator: "\n")
    }

    private static func join(_ lines: [Line]) -> String {
        lines.map { $0.content + $0.terminator }.joined()
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            default:
                result.append(character)
                result.append(next)
            }
        }
        return result
    }

    /// Splits on `\n` / `\r\n` at the unicode-scalar level -- `Character`
    /// treats `\r\n` as a single grapheme, so `split(separator:)` would miss it.
    private static func splitLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                var terminator = "\n"
                if current.last == "\r" {
                    current.removeLast()
                    terminator = "\r\n"
                }
                lines.append(Line(content: String(current), terminator: terminator))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty {
            lines.append(Line(content: String(current), terminator: ""))
        }
        return lines
    }

    // MARK: - Scanning

    private static func parse(_ lines: [Line]) -> (entries: [Entry], tables: [Table], blocks: [ArrayBlock]) {
        let contents = lines.map { Array($0.content) }
        var tables = [Table(path: "", isArray: false, headerLine: nil, lastLine: -1)]
        var entries: [Entry] = []
        var blocks: [ArrayBlock] = []
        var current = 0
        var firstHeaderLine: Int?
        var index = 0

        while index < contents.count {
            let chars = contents[index]
            guard let first = chars.firstIndex(where: { $0 != " " && $0 != "\t" }),
                  chars[first] != "#" else {
                index += 1
                continue
            }

            if chars[first] == "[" {
                let isArray = first + 1 < chars.count && chars[first + 1] == "["
                let bodyStart = first + (isArray ? 2 : 1)
                let body = chars[bodyStart...].prefix { $0 != "]" }
                tables.append(Table(
                    path: splitDotted(Array(body)).joined(separator: "."),
                    isArray: isArray,
                    headerLine: index,
                    lastLine: index
                ))
                current = tables.count - 1
                if isArray {
                    blocks.append(ArrayBlock(path: tables[current].path, headerLine: index, lastLine: index, entries: []))
                }
                if firstHeaderLine == nil { firstHeaderLine = index }
                index += 1
                continue
            }

            guard let equals = equalsIndex(in: chars, from: first) else {
                index += 1
                continue
            }
            var valueStart = equals + 1
            while valueStart < chars.count, chars[valueStart] == " " || chars[valueStart] == "\t" {
                valueStart += 1
            }
            guard valueStart < chars.count, chars[valueStart] != "#",
                  let end = scanValue(contents, line: index, column: valueStart) else {
                index += 1
                continue
            }

            let key = splitDotted(Array(chars[first..<equals]))
            if tables[current].isArray {
                blocks[blocks.count - 1].entries.append(Entry(
                    path: key.joined(separator: "."),
                    startLine: index, startCol: valueStart, endLine: end.line, endCol: end.column
                ))
                blocks[blocks.count - 1].lastLine = end.line
            } else {
                let path = ([tables[current].path].filter { !$0.isEmpty } + key).joined(separator: ".")
                entries.append(Entry(
                    path: path,
                    startLine: index,
                    startCol: valueStart,
                    endLine: end.line,
                    endCol: end.column
                ))
            }
            tables[current].lastLine = end.line
            index = end.line + 1
        }

        if tables[0].lastLine == -1 {
            tables[0].lastLine = (firstHeaderLine ?? contents.count) - 1
        }
        return (entries, tables, blocks)
    }

    /// Index of the first `=` outside quotes at or after `from`.
    private static func equalsIndex(in chars: [Character], from: Int) -> Int? {
        var quote: Character?
        var index = from
        while index < chars.count {
            let character = chars[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func splitDotted(_ chars: [Character]) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in chars {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// End (exclusive column, on the returned line) of the value starting at
    /// `line`/`column`, or nil if it cannot be delimited.
    private static func scanValue(
        _ contents: [[Character]], line: Int, column: Int
    ) -> (line: Int, column: Int)? {
        let chars = contents[line]
        let first = chars[column]

        if first == "\"" || first == "'" {
            return scanString(contents, line: line, column: column)
        }

        if first == "[" || first == "{" {
            var depth = 0
            var l = line
            var c = column
            while l < contents.count {
                while c < contents[l].count {
                    let character = contents[l][c]
                    if character == "\"" || character == "'" {
                        guard let end = scanString(contents, line: l, column: c) else { return nil }
                        l = end.line
                        c = end.column
                        continue
                    }
                    if character == "#" { break }
                    if character == "[" || character == "{" { depth += 1 }
                    if character == "]" || character == "}" {
                        depth -= 1
                        if depth == 0 { return (l, c + 1) }
                    }
                    c += 1
                }
                l += 1
                c = 0
            }
            return nil
        }

        var end = column
        while end < chars.count, chars[end] != " ", chars[end] != "\t", chars[end] != "#" {
            end += 1
        }
        return (line, end)
    }

    private static func scanString(
        _ contents: [[Character]], line: Int, column: Int
    ) -> (line: Int, column: Int)? {
        let chars = contents[line]
        let quote = chars[column]
        let isBasic = quote == "\""
        let isTriple = column + 2 < chars.count && chars[column + 1] == quote && chars[column + 2] == quote

        if !isTriple {
            var index = column + 1
            while index < chars.count {
                if isBasic, chars[index] == "\\" {
                    index += 2
                    continue
                }
                if chars[index] == quote { return (line, index + 1) }
                index += 1
            }
            return nil
        }

        var l = line
        var c = column + 3
        while l < contents.count {
            let row = contents[l]
            while c < row.count {
                if isBasic, row[c] == "\\" {
                    c += 2
                    continue
                }
                if row[c] == quote, c + 2 < row.count, row[c + 1] == quote, row[c + 2] == quote {
                    return (l, c + 3)
                }
                c += 1
            }
            l += 1
            c = 0
        }
        return nil
    }
}
