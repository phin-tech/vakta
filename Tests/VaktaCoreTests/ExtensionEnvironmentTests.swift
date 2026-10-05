//
//  ExtensionEnvironmentTests.swift
//  VaktaCoreTests
//
//  Login-shell variables an Extension may receive: declared names and
//  prefixes only, never Vakta's own, plus parsing the login shell's `env`.

import XCTest
@testable import Vakta

final class ExtensionEnvironmentTests: XCTestCase {
    private let source = [
        "KATA_AUTH_TOKEN": "t0k3n", "KATA_TRUST_PRIVATE_NETWORK": "1", "KATALOG": "no",
        "GITHUB_TOKEN": "gh", "PATH": "/evil", "HOME": "/elsewhere", "VAKTA_EXTENSION_ID": "spoof",
    ]

    func test_passthrough_exactNamesAndPrefixes_only() {
        XCTAssertEqual(ExtensionEnvironment.passthrough(["KATA_*"], from: source), [
            "KATA_AUTH_TOKEN": "t0k3n", "KATA_TRUST_PRIVATE_NETWORK": "1",
        ])
        XCTAssertEqual(ExtensionEnvironment.passthrough(["GITHUB_TOKEN", "MISSING"], from: source), ["GITHUB_TOKEN": "gh"])
        XCTAssertEqual(ExtensionEnvironment.passthrough([], from: source), [:])
    }

    func test_passthrough_neverIncludesReservedNames() {
        XCTAssertEqual(ExtensionEnvironment.passthrough(["PATH", "HOME", "VAKTA_EXTENSION_ID", "VAKTA_*"], from: source), [:])
    }

    func test_problems() {
        XCTAssertEqual(ExtensionEnvironment.problems(["KATA_*", "GITHUB_TOKEN", "lower_ok"]), [])
        XCTAssertEqual(ExtensionEnvironment.problems(["*"]), ["Environment entry “*” must name a variable or a PREFIX_*."])
        XCTAssertEqual(ExtensionEnvironment.problems(["BAD-NAME"]), ["Environment entry “BAD-NAME” must name a variable or a PREFIX_*."])
        XCTAssertEqual(ExtensionEnvironment.problems(["A*B"]), ["Environment entry “A*B” must name a variable or a PREFIX_*."])
        XCTAssertEqual(ExtensionEnvironment.problems(["PATH", "VAKTA_*"]), [
            "Environment entry “PATH” is set by Vakta.", "Environment entry “VAKTA_*” is set by Vakta.",
        ])
    }

    func test_manifestEnvironment_decodesAndIsValidated() throws {
        let manifest = try XCTUnwrap(ExtensionManifest.decode(Data(#"{"id":"x","name":"X","command":["./run"],"environment":["KATA_*","HOME"]}"#.utf8)))
        XCTAssertEqual(manifest.environment, ["KATA_*", "HOME"])
        XCTAssertEqual(manifest.problems, ["Environment entry “HOME” is set by Vakta."])
        XCTAssertEqual(ExtensionManifest.decode(Data(#"{"id":"x","name":"X","command":["./run"]}"#.utf8))?.environment, [])
    }

    func test_extractEnvironment_parsesEnvOutput_skippingContinuationLines() {
        let output = "PATH=/usr/bin:/bin\nKATA_AUTH_TOKEN=abc=def\nMULTI=line one\nline two\n=junk\nEMPTY=\n"
        XCTAssertEqual(ShellEnvironment.extractEnvironment(from: output), [
            "PATH": "/usr/bin:/bin", "KATA_AUTH_TOKEN": "abc=def", "MULTI": "line one", "EMPTY": "",
        ])
    }
}
