//
//  ProtocolTestSupport.swift
//  VaktaExtensionKitTests
//
//  Loads the golden fixtures in extensions/protocol/fixtures (the wire
//  contract, shared with non-Swift Extensions) and compares JSON by meaning
//  rather than by bytes: key order and whitespace are not part of the
//  contract.

import Foundation
import XCTest
import VaktaExtensionKit

enum ProtocolFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // VaktaExtensionKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("extensions/protocol/fixtures")

    /// The fixture minified to one protocol line (fixtures are pretty-printed
    /// for reading).
    static func line(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = directory.appendingPathComponent(name + ".json")
        let data = try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(url.path)", file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: data)
        let minified = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: minified, as: UTF8.self)
    }

    static var allNames: [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}

/// Parses inline JSON into a `JSONValue` for payload-level cases.
func jsonValue(_ json: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

func assertSameJSON(_ actual: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
    func object(_ text: String) -> NSObject? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? NSObject
    }
    guard let actualObject = object(actual) else {
        return XCTFail("not JSON: \(actual)", file: file, line: line)
    }
    XCTAssertEqual(actualObject, object(expected), "\n  actual:   \(actual)\n  expected: \(expected)", file: file, line: line)
}
