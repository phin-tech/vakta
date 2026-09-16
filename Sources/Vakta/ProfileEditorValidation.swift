//
//  ProfileEditorValidation.swift
//  Vakta
//
//  Pure parsing/validation for `ProfileEditorView`'s line-oriented
//  environment/scrub text fields, kept separate from SwiftUI so it's
//  directly testable. Previously (`ProfileEditorView.parseEnvironment` /
//  `.parseLines`) malformed lines were silently dropped; every rejection
//  here instead produces a reportable error the view surfaces before Save.

import Foundation

/// The result of parsing the "Set (KEY=VALUE per line)" field.
struct ParsedEnvironment: Equatable {
    var entries: [String: String] = [:]
    var errors: [String] = []
}

enum ProfileEditorParsing {
    /// `KEY=VALUE` lines -> dictionary. Blank lines are formatting and
    /// skipped silently; a non-blank line missing `=`, with an empty key, or
    /// with a key that isn't a valid environment-variable name is an error
    /// (the value after `=` may itself contain `=` and isn't otherwise
    /// restricted -- it's never shell-interpolated, only passed through
    /// libghostty's structured `env_vars`, see `Profile.makeSurfaceOptions`).
    static func parseEnvironment(_ text: String) -> ParsedEnvironment {
        var result = ParsedEnvironment()
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let eq = line.firstIndex(of: "=") else {
                result.errors.append("Line \(index + 1): missing \"=\" in \"\(line)\"")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                result.errors.append("Line \(index + 1): missing a variable name before \"=\"")
                continue
            }
            guard LaunchCommandPlanner.isValidEnvironmentKey(key) else {
                result.errors.append("Line \(index + 1): \"\(key)\" isn't a valid variable name")
                continue
            }
            result.entries[key] = String(line[line.index(after: eq)...])
        }
        return result
    }

    /// One variable name per line for the "Clear" (scrub) field. Blank lines
    /// are skipped silently; a non-blank line that isn't a valid
    /// environment-variable name is an error -- it becomes a bare `-u KEY`
    /// shell token (see `Profile.resolvedCommand`), so an invalid one is
    /// both meaningless and, if ever left unvalidated, an injection vector.
    static func parseScrubKeys(_ text: String) -> (keys: [String], errors: [String]) {
        var keys: [String] = []
        var errors: [String] = []
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if LaunchCommandPlanner.isValidEnvironmentKey(trimmed) {
                keys.append(trimmed)
            } else {
                errors.append("Line \(index + 1): \"\(trimmed)\" isn't a valid variable name")
            }
        }
        return (keys, errors)
    }
}
