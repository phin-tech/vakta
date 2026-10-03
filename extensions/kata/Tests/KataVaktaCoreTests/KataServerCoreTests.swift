//
//  KataServerCoreTests.swift
//  KataVaktaCoreTests

import XCTest
import VaktaExtensionKit
@testable import KataVaktaCore

final class KataServerCoreTests: XCTestCase {
    func test_initializeResult_answersWithTheKitAPIVersion() {
        let params = InitializeParams(
            apiVersion: vaktaExtensionAPIVersion, host: HostInfo(name: "Vakta", version: "1"),
            capabilities: HostCapabilities(viewKinds: [], effects: [])
        )
        XCTAssertEqual(KataServerCore.initializeResult(for: params), InitializeResult(apiVersion: vaktaExtensionAPIVersion, name: "Kata"))
    }

    func test_describe_namesTheFocusedSessionAndItsRepo() {
        let contexts = [
            ExtensionContext(sessionKey: SessionKey(backend: "tmux", sessionName: "a"), cwd: "/tmp", gitRoot: nil, branch: nil, workspace: nil, focused: false),
            ExtensionContext(sessionKey: SessionKey(backend: "herdr", sessionName: "vakta"), cwd: "/r/Sources", gitRoot: "/r", branch: "main", workspace: nil, focused: true),
        ]
        XCTAssertEqual(KataServerCore.describe(contexts), "contexts: 2 session(s), focused herdr:vakta at /r")
        XCTAssertEqual(KataServerCore.describe([]), "contexts: 0 session(s)")
    }
}
