//
//  HerdrConfigSavePlanner.swift
//  Vakta
//
//  Pure decisions around saving herdr's config.toml: what `herdr config
//  check` said, and whether saving is safe given whether the file changed on
//  disk since it was loaded. The shell supplies fingerprints and the check
//  result; nothing here does I/O.

import Foundation

/// One problem reported by `herdr config check`. herdr reports only the
/// first error in a file.
struct HerdrConfigDiagnostic: Equatable {
    let line: Int
    let column: Int
    let message: String

    /// Parses `herdr config check` output, e.g.
    /// ```
    /// config parse error: TOML parse error at line 2, column 20
    ///   |
    /// 2 | tab_bar_position = "sideways"
    ///   |                    ^^^^^^^^^^
    /// unknown variant `sideways`, expected `top` or `bottom`
    /// ; using defaults
    /// ```
    static func parse(checkOutput: String) -> [HerdrConfigDiagnostic] {
        let lines = checkOutput.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { $0.contains("TOML parse error at line") }),
              let match = lines[headerIndex].range(
                of: #"line (\d+), column (\d+)"#, options: .regularExpression),
              case let numbers = lines[headerIndex][match].split(whereSeparator: { !$0.isNumber }),
              numbers.count == 2,
              let line = Int(numbers[0]), let column = Int(numbers[1])
        else {
            // Not a TOML syntax error: herdr also reports semantic problems
            // (e.g. `shift+cmd+t: kept keys.new_tab, disabled keys.rename_tab`)
            // one per line, without a position.
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("config:") && !$0.hasPrefix(";") }
                .map { HerdrConfigDiagnostic(line: 0, column: 0, message: $0) }
        }

        var message: [String] = []
        var seenCaret = false
        for text in lines[(headerIndex + 1)...] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !seenCaret {
                if trimmed.hasPrefix("|"), trimmed.contains("^") { seenCaret = true }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix(";") { break }
            message.append(trimmed)
        }
        return [HerdrConfigDiagnostic(line: line, column: column, message: message.joined(separator: " "))]
    }
}

enum HerdrConfigCheckResult: Equatable {
    case valid
    case invalid([HerdrConfigDiagnostic])
    /// The `herdr` binary could not be run, so the candidate is unverified.
    case unavailable
}

enum HerdrConfigSaveDecision: Equatable {
    case save
    case conflictExternalEdit
    case rejectInvalid([HerdrConfigDiagnostic])
    case needsUnverifiedConfirmation
}

enum HerdrConfigSavePlanner {
    static func decide(
        baseFingerprint: String,
        currentFingerprint: String,
        check: HerdrConfigCheckResult
    ) -> HerdrConfigSaveDecision {
        if case .invalid(let diagnostics) = check { return .rejectInvalid(diagnostics) }
        if baseFingerprint != currentFingerprint { return .conflictExternalEdit }
        if check == .unavailable { return .needsUnverifiedConfirmation }
        return .save
    }
}
