//
//  LaunchCommandPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `LaunchCommandPlanner` and `Profile.resolvedCommand`:
//  placeholder quoting, template validation, and environment-key validation.
//  No file I/O, no subprocess execution -- see `LaunchCommandShellTests` for
//  proving these hold when a real shell actually parses the result.

import XCTest
@testable import Vakta

final class LaunchCommandPlannerTests: XCTestCase {
    // MARK: shellQuote

    func test_shellQuote_plainValue_isWrappedInSingleQuotes() {
        XCTAssertEqual(LaunchCommandPlanner.shellQuote("vakta-abc123"), "'vakta-abc123'")
    }

    func test_shellQuote_embeddedSingleQuote_isEscaped() {
        XCTAssertEqual(LaunchCommandPlanner.shellQuote("it's"), "'it'\\''s'")
    }

    func test_shellQuote_empty_producesEmptyQuotedWord() {
        XCTAssertEqual(LaunchCommandPlanner.shellQuote(""), "''")
    }

    // MARK: substitutePlaceholder -- table-driven over the AC's metacharacter list

    private struct DangerousName {
        let label: String
        let value: String
    }

    private static let dangerousNames: [DangerousName] = [
        .init(label: "space", value: "has space"),
        .init(label: "single quote", value: "o'brien"),
        .init(label: "double quote", value: "say \"hi\""),
        .init(label: "dollar substitution", value: "$(touch pwned)"),
        .init(label: "backtick substitution", value: "`touch pwned`"),
        .init(label: "semicolon", value: "a; touch pwned"),
        .init(label: "newline", value: "a\ntouch pwned"),
        .init(label: "leading dash", value: "-rf"),
        .init(label: "ampersand", value: "a & touch pwned"),
        .init(label: "pipe", value: "a | touch pwned")
    ]

    func test_substitutePlaceholder_everyDangerousName_wrapsExactlyThatValueInQuotes() {
        for name in Self.dangerousNames {
            let result = LaunchCommandPlanner.substitutePlaceholder(in: "--session {name}", sessionName: name.value)
            XCTAssertEqual(
                result,
                "--session " + LaunchCommandPlanner.shellQuote(name.value),
                name.label
            )
        }
    }

    // MARK: validateArgumentsTemplate

    private func assertValid(_ template: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .success = LaunchCommandPlanner.validateArgumentsTemplate(template) else {
            return XCTFail("expected \"\(template)\" to be a valid template", file: file, line: line)
        }
    }

    func test_validateArgumentsTemplate_builtinHerdrSyntax_isValid() {
        assertValid("--session {name}")
    }

    func test_validateArgumentsTemplate_builtinTmuxSyntax_isValid() {
        assertValid("new-session -A -s {name}")
    }

    func test_validateArgumentsTemplate_documentedRemoteSyntax_isValid() {
        assertValid("--remote me@host --session {name}")
    }

    func test_validateArgumentsTemplate_noPlaceholderAtAll_isValid() {
        assertValid("")
    }

    func test_validateArgumentsTemplate_quotesWithNoPlaceholder_isValid() {
        // A template that never references {name} isn't touched by this
        // rule at all -- its own quoting, for whatever reason, is the
        // profile author's business, not a placeholder-ambiguity risk.
        assertValid("-c \"some fixed literal\"")
    }

    func test_validateArgumentsTemplate_flagEqualsPlaceholder_isValid() {
        // `--session={name}` is unambiguous: the shell still sees exactly
        // one word (`--session=` concatenated with the quoted substitution).
        assertValid("--session={name}")
    }

    func test_validateArgumentsTemplate_literalTextGluedBeforePlaceholder_isRejected() {
        guard case .failure = LaunchCommandPlanner.validateArgumentsTemplate("pre{name}") else {
            return XCTFail("expected text glued directly before {name} to be rejected")
        }
    }

    func test_validateArgumentsTemplate_literalTextGluedAfterPlaceholder_isRejected() {
        guard case .failure = LaunchCommandPlanner.validateArgumentsTemplate("{name}post") else {
            return XCTFail("expected text glued directly after {name} to be rejected")
        }
    }

    func test_validateArgumentsTemplate_userAddedDoubleQuotes_isRejected() {
        guard case .failure = LaunchCommandPlanner.validateArgumentsTemplate("--session \"{name}\"") else {
            return XCTFail("expected a template with its own quotes around {name} to be rejected")
        }
    }

    func test_validateArgumentsTemplate_userAddedSingleQuotes_isRejected() {
        guard case .failure = LaunchCommandPlanner.validateArgumentsTemplate("--session '{name}'") else {
            return XCTFail("expected a template with its own quotes around {name} to be rejected")
        }
    }

    // MARK: isValidEnvironmentKey

    func test_isValidEnvironmentKey_typicalNames_areValid() {
        for key in ["HERDR_ENV", "PATH", "_private", "A1"] {
            XCTAssertTrue(LaunchCommandPlanner.isValidEnvironmentKey(key), key)
        }
    }

    func test_isValidEnvironmentKey_invalidNames_areRejected() {
        for key in ["", " ", "1STARTS_WITH_DIGIT", "HAS SPACE", "HAS-DASH", "HAS;SEMI", "HAS=EQUALS", "HAS'QUOTE"] {
            XCTAssertFalse(LaunchCommandPlanner.isValidEnvironmentKey(key), key)
        }
    }
}
