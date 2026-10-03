//
//  ExtensionManifestTests.swift
//  VaktaCoreTests
//
//  Decoding and validating `vakta-extension.json`, and resolving the
//  executable Trust pins.

import XCTest
@testable import Vakta

final class ExtensionManifestTests: XCTestCase {
    private func manifest(_ json: String) throws -> ExtensionManifest {
        try XCTUnwrap(ExtensionManifest.decode(Data(json.utf8)), json)
    }

    private let full = #"""
        {"id": "kata", "name": "Kata", "description": "Issues for this repo",
         "command": ["./.build/release/kata-vakta", "serve"],
         "build": [["swift", "build", "-c", "release"]],
         "panelViews": [{"id": "issues", "title": "Issues", "symbol": "checklist"}]}
        """#

    func test_decodesEveryField() throws {
        XCTAssertEqual(try manifest(full), ExtensionManifest(
            id: "kata", name: "Kata", description: "Issues for this repo",
            command: ["./.build/release/kata-vakta", "serve"],
            build: [["swift", "build", "-c", "release"]],
            panelViews: [.init(id: "issues", title: "Issues", symbol: "checklist")]
        ))
    }

    func test_omittedBuildAndPanelViews_areEmpty() throws {
        let decoded = try manifest(#"{"id": "x", "name": "X", "command": ["./run"]}"#)
        XCTAssertEqual(decoded.build, [])
        XCTAssertEqual(decoded.panelViews, [])
        XCTAssertNil(decoded.description)
        XCTAssertEqual(decoded.problems, [])
    }

    func test_notAManifest_decodesToNil() {
        for json in ["", "[]", #"{"name": "X"}"#, #"{"id": "x", "name": "X", "command": "./run"}"#] {
            XCTAssertNil(ExtensionManifest.decode(Data(json.utf8)), json)
        }
    }

    func test_validManifest_hasNoProblems() throws {
        XCTAssertEqual(try manifest(full).problems, [])
    }

    func test_problems() throws {
        let cases: [(String, String)] = [
            (#"{"id": "", "name": "X", "command": ["./run"]}"#, "ID is required."),
            (#"{"id": "Kata Ext", "name": "X", "command": ["./run"]}"#,
             "ID may contain only lowercase letters, digits, dots and dashes."),
            (#"{"id": "x", "name": " ", "command": ["./run"]}"#, "Name is required."),
            (#"{"id": "x", "name": "X", "command": []}"#, "Command is required."),
            (#"{"id": "x", "name": "X", "command": ["/usr/bin/python3", "x.py"]}"#,
             "Command must start with a path inside the extension directory, like ./run."),
            (#"{"id": "x", "name": "X", "command": ["../elsewhere/run"]}"#,
             "Command must start with a path inside the extension directory, like ./run."),
            (#"{"id": "x", "name": "X", "command": ["python3"]}"#,
             "Command must start with a path inside the extension directory, like ./run."),
            (#"{"id": "x", "name": "X", "command": ["./run"], "build": [[]]}"#, "Build commands can't be empty."),
            (#"{"id": "x", "name": "X", "command": ["./run"], "panelViews": [{"id": "a", "title": "A", "symbol": "x"}, {"id": "a", "title": "B", "symbol": "y"}]}"#,
             "Panel view IDs must be unique (a)."),
            (#"{"id": "x", "name": "X", "command": ["./run"], "panelViews": [{"id": "a", "title": "", "symbol": ""}]}"#,
             "Panel view a needs a title and a symbol."),
        ]
        for (json, problem) in cases {
            XCTAssertEqual(try manifest(json).problems, [problem], json)
        }
    }

    func test_executableURL_resolvesInsideTheDirectory() throws {
        let directory = URL(fileURLWithPath: "/tmp/ext", isDirectory: true)
        let resolved = try manifest(full).executableURL(in: directory)
        XCTAssertEqual(resolved?.path, "/tmp/ext/.build/release/kata-vakta")

        let nested = try manifest(#"{"id": "x", "name": "X", "command": ["bin/../run"]}"#)
        XCTAssertEqual(nested.executableURL(in: directory)?.path, "/tmp/ext/run")
    }

    func test_executableURL_isNilWhenAbsoluteOrEscaping() throws {
        let directory = URL(fileURLWithPath: "/tmp/ext", isDirectory: true)
        for command in [#"["/bin/sh"]"#, #"["../run"]"#, #"["bin/../../run"]"#] {
            let decoded = try manifest(#"{"id": "x", "name": "X", "command": \#(command)}"#)
            XCTAssertNil(decoded.executableURL(in: directory), command)
        }
    }
}
