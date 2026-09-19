//
//  PaletteRootWorkspacePlannerTests.swift
//  VaktaCoreTests
//
//  RED coverage for loading workspace rows into the root Cmd-K palette.

import XCTest
@testable import Vakta

final class PaletteRootWorkspacePlannerTests: XCTestCase {
    func test_fetchSessionIDs_preservesOrder_andExcludesUnsupportedSessions() {
        let first = UUID()
        let unsupported = UUID()
        let last = UUID()

        XCTAssertEqual(
            PaletteRootWorkspacePlanner.fetchSessionIDs([
                PaletteWorkspaceSession(id: first, supportsWorkspaces: true),
                PaletteWorkspaceSession(id: unsupported, supportsWorkspaces: false),
                PaletteWorkspaceSession(id: last, supportsWorkspaces: true)
            ]),
            [first, last]
        )
    }
}
