//
//  HerdrConfigLocatorTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for resolving herdr's config path and fingerprinting
//  its contents. Pure: environment and home are supplied, nothing is read.

import XCTest
@testable import Vakta

final class HerdrConfigLocatorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func test_resolve_defaultsToDotConfigHerdrUnderHome() {
        XCTAssertEqual(
            HerdrConfigLocator.resolve(environment: [:], home: home).path,
            "/Users/someone/.config/herdr/config.toml"
        )
    }

    func test_resolve_honorsHerdrConfigPathOverride() {
        XCTAssertEqual(
            HerdrConfigLocator.resolve(environment: ["HERDR_CONFIG_PATH": "/tmp/x/custom.toml"], home: home).path,
            "/tmp/x/custom.toml"
        )
    }

    func test_resolve_emptyOverride_fallsBackToDefault() {
        XCTAssertEqual(
            HerdrConfigLocator.resolve(environment: ["HERDR_CONFIG_PATH": ""], home: home).path,
            "/Users/someone/.config/herdr/config.toml"
        )
    }

    func test_resolve_overrideWithTilde_expandsAgainstSuppliedHome() {
        XCTAssertEqual(
            HerdrConfigLocator.resolve(environment: ["HERDR_CONFIG_PATH": "~/cfg/herdr.toml"], home: home).path,
            "/Users/someone/cfg/herdr.toml"
        )
    }

    func test_fingerprint_isStableAndContentSensitive_includingLineEndings() {
        XCTAssertEqual(HerdrConfigFingerprint.of("a = 1\n"), HerdrConfigFingerprint.of("a = 1\n"))
        XCTAssertNotEqual(HerdrConfigFingerprint.of("a = 1\n"), HerdrConfigFingerprint.of("a = 1\r\n"))
        XCTAssertNotEqual(HerdrConfigFingerprint.of(""), HerdrConfigFingerprint.missing)
    }
}
