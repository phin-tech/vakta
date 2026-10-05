//
//  BuiltInExtensionsTests.swift
//  VaktaCoreTests
//
//  Where Built-in Extensions are found (app bundle vs development
//  checkout) and how they're reconciled with the registry.

import XCTest
@testable import Vakta

final class BuiltInExtensionsTests: XCTestCase {
    func test_roots_appBundle_usesContentsExtensions() {
        let roots = BuiltInExtensions.roots(
            bundleURL: URL(fileURLWithPath: "/Applications/Vakta.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Vakta.app/Contents/MacOS/Vakta"),
            fileExists: { _ in false }
        )
        XCTAssertEqual(roots.map(\.path), ["/Applications/Vakta.app/Contents/Extensions"])
    }

    func test_roots_swiftRun_usesTheRepositoryExtensionsFolder() {
        let roots = BuiltInExtensions.roots(
            bundleURL: URL(fileURLWithPath: "/src/vakta/.build/arm64-apple-macosx/debug"),
            executableURL: URL(fileURLWithPath: "/src/vakta/.build/arm64-apple-macosx/debug/Vakta"),
            fileExists: { $0 == "/src/vakta/Package.swift" }
        )
        XCTAssertEqual(roots.map(\.path), ["/src/vakta/extensions"])
    }

    func test_roots_none_whenNeitherAppNorCheckout() {
        XCTAssertEqual(BuiltInExtensions.roots(
            bundleURL: URL(fileURLWithPath: "/tmp/x"), executableURL: URL(fileURLWithPath: "/tmp/x/Vakta"), fileExists: { _ in false }
        ), [])
    }

    func test_reconcile_addsNewBuiltIns_dropsUnshippedOnes_andKeepsSwitches() {
        let linked = LinkedExtensionRecord(directory: "/src/kata", enabled: true, developerMode: true, approved: nil)
        let keptBuiltIn = LinkedExtensionRecord(directory: "/app/github", enabled: false, developerMode: false, approved: nil, notifications: false, builtIn: true)
        let gone = LinkedExtensionRecord(directory: "/app/old", enabled: true, developerMode: false, approved: nil, builtIn: true)

        let records = BuiltInExtensions.reconcile([linked, keptBuiltIn, gone], builtInDirectories: ["/app/github", "/app/new"])

        XCTAssertEqual(records, [
            linked,
            keptBuiltIn,
            LinkedExtensionRecord(directory: "/app/new", enabled: true, developerMode: false, approved: nil, builtIn: true),
        ])
    }
}
