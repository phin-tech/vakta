//
//  LaunchCommandPlanner.swift
//  Vakta
//
//  Pure business rules for turning a `Profile`'s command/arguments template
//  plus an interpolated session name into a safe shell command line, with no
//  Ghostty/AppKit dependency. `Profile.resolvedCommand(sessionName:)` is the
//  shell adapter that calls into this.
//
//  The threat model: `sessionName` is DATA, not something the user typed as
//  part of the profile. It can come from `herdr session list` / `tmux
//  list-sessions` output (an external process, not necessarily benign -- see
//  `SessionDiscovery`), or from a hand-edited `workspace.json`. The profile's
//  own `command`/`arguments` text is authored by the user in the editor --
//  they already fully control it (typing `rm -rf ~` as your own command is
//  not an injection, it's just a bad profile), so only the *substituted*
//  value needs defending, not the template's literal text.

import Foundation

enum LaunchCommandPlanner {
    struct ValidationError: Error, Equatable, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// POSIX single-quote escaping: wraps `value` in `'...'`, replacing each
    /// embedded `'` with `'\''` (close quote, backslash-escaped literal
    /// quote, reopen quote). Once quoted, `value` is exactly one shell word
    /// to the parser regardless of its content -- spaces, `$(...)`,
    /// backticks, `;`, newlines, and a leading `-` are all inert.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Rejects an arguments template whose `{name}` usage is ambiguous. A
    /// template that never references `{name}` at all is untouched by any of
    /// this -- its quoting/content, if any, is entirely the profile author's
    /// own business. Where `{name}` IS used:
    ///
    /// - No quote character anywhere in the template. `{name}` is always
    ///   substituted already safely quoted (see `substitutePlaceholder`); a
    ///   template like `"{name}"` or `'{name}'` would nest the profile
    ///   author's quoting around the substitution's own, which either breaks
    ///   the command or silently produces something other than what either
    ///   quoting layer intended. There is no context that needs its own
    ///   quotes around `{name}` -- the substitution already handles it.
    /// - Each `{name}` occurrence must stand alone as its own shell word, or
    ///   immediately follow `=` (the `--flag=value` form, e.g.
    ///   `--session={name}`, is unambiguous: the shell still sees exactly one
    ///   word). Anything else glued directly onto the placeholder -- e.g.
    ///   `pre{name}` or `{name}post` -- silently produces a session name
    ///   that isn't `{name}`'s value at all once the shell concatenates the
    ///   quoted substitution with adjacent literal text, with no injection
    ///   risk but a wrong result the profile author almost certainly didn't
    ///   intend.
    static func validateArgumentsTemplate(_ template: String) -> Result<Void, ValidationError> {
        guard template.contains("{name}") else { return .success(()) }

        if template.contains("'") || template.contains("\"") {
            return .failure(ValidationError(
                message: "Arguments can't contain quote characters together with {name}. {name} is "
                    + "already substituted as one safely-quoted value -- wrapping it in your own "
                    + "quotes would break or double-quote it."
            ))
        }

        var searchRange = template.startIndex..<template.endIndex
        while let placeholderRange = template.range(of: "{name}", range: searchRange) {
            let precededOK = placeholderRange.lowerBound == template.startIndex || {
                let before = template[template.index(before: placeholderRange.lowerBound)]
                return before == " " || before == "="
            }()
            let followedOK = placeholderRange.upperBound == template.endIndex
                || template[placeholderRange.upperBound] == " "
            guard precededOK, followedOK else {
                return .failure(ValidationError(
                    message: "{name} must stand alone as its own argument (or follow \"=\"), e.g. "
                        + "\"--session {name}\" or \"--session={name}\" -- it can't be glued to other text."
                ))
            }
            searchRange = placeholderRange.upperBound..<template.endIndex
        }
        return .success(())
    }

    /// Substitutes every `{name}` in `template` with `sessionName`, quoted.
    /// Callers should validate the template first (`validateArgumentsTemplate`);
    /// this still quotes unconditionally even if they didn't, since making
    /// the substitution safe cannot itself be the thing that's skipped.
    static func substitutePlaceholder(in template: String, sessionName: String) -> String {
        template.replacingOccurrences(of: "{name}", with: shellQuote(sessionName))
    }

    /// A POSIX environment-variable name: `[A-Za-z_][A-Za-z0-9_]*`. Both the
    /// "set" and "clear" (scrub) lists are validated against this -- a
    /// scrubbed key becomes a bare `-u KEY` shell token (see
    /// `Profile.resolvedCommand`), so an invalid one isn't just meaningless,
    /// it's an injection vector if left unquoted and unvalidated.
    static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }
        return key.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }
}
