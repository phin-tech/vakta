//
//  HerdrCustomCommand.swift
//  Vakta
//
//  Pure model for herdr's `[[keys.command]]` custom command bindings: build
//  from a config block, validate the documented fields, and produce the
//  ordered field list to write back. `plugin_action` commands carry fields the
//  reference doesn't document, so the form leaves them read-only (Raw tab).

import Foundation

struct HerdrCustomCommand: Equatable {
    static let tablePath = "keys.command"
    static let types = ["popup", "pane", "shell", "plugin_action"]

    var key: String
    var type: String
    var command: String
    var description: String
    var width: String
    var height: String

    init(key: String, type: String, command: String, description: String, width: String, height: String) {
        self.key = key
        self.type = type
        self.command = command
        self.description = description
        self.width = width
        self.height = height
    }

    init(entry: HerdrConfigArrayEntry) {
        func text(_ name: String) -> String {
            switch entry.fields[name] {
            case .string(let value)?: return value
            case .integer(let value)?: return String(value)
            case .raw(let value)?: return value
            default: return ""
            }
        }
        self.init(
            key: text("key"), type: text("type"), command: text("command"),
            description: text("description"), width: text("width"), height: text("height"))
    }

    var isFormEditable: Bool { type != "plugin_action" }

    var problems: [String] {
        var found: [String] = []
        if key.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("Key is required.")
        } else if case .failure(let error) = HerdrKeyChord.parse(key) {
            found.append(error.message)
        }
        if !Self.types.contains(type) {
            found.append("Type must be one of: \(Self.types.joined(separator: ", ")).")
        }
        if type != "plugin_action", command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("Command is required.")
        }
        for (name, value) in [("Width", width), ("Height", height)] where !value.isEmpty && !Self.isSize(value) {
            found.append("\(name) must be cells (24) or a percentage (80%).")
        }
        return found
    }

    /// Fields to write, in documented order, omitting empty optional ones.
    /// Sizes that are plain numbers are written as strings, matching herdr's
    /// documented `"80%"` style; herdr accepts terminal cells or percentages.
    var fieldPairs: [(String, HerdrConfigValue)] {
        var pairs: [(String, HerdrConfigValue)] = [("key", .string(key)), ("type", .string(type))]
        pairs.append(("command", .string(command)))
        if !description.isEmpty { pairs.append(("description", .string(description))) }
        if !width.isEmpty { pairs.append(("width", .string(width))) }
        if !height.isEmpty { pairs.append(("height", .string(height))) }
        return pairs
    }

    private static func isSize(_ text: String) -> Bool {
        let digits = text.hasSuffix("%") ? String(text.dropLast()) : text
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}
