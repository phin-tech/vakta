//
//  SidebarWidthCombineTests.swift
//  VaktaIntegrationTests
//
//  Shell case proving the actual Combine emission-ordering bug this issue
//  was filed for, against the real `SidebarSettingsStore` -- not just that
//  `SidebarWidthPlanner`'s pure math looks right (see
//  `SidebarWidthPlannerTests`). `AppDelegate.applySidebarWidth` itself needs
//  a real `NSSplitView` inside a window to assert a divider position
//  against, which testing.md reserves for a desktop smoke check; this
//  isolates the exact mechanism that made the old code wrong -- `@Published`
//  emits from `willSet`, so a synchronous re-read of the source property
//  inside its own subscriber sees the OLD value, while the emitted
//  parameter already has the new one -- using the real store and a real
//  Combine subscription, not a fixture standing in for `@Published`.

import Combine
import XCTest
@testable import Vakta

@MainActor
final class SidebarWidthCombineTests: XCTestCase {
    private var tempDirectory: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarWidthCombineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func test_collapseStylePublisher_emittedValueLeadsTheStoredProperty() {
        let store = SidebarSettingsStore(root: tempDirectory)
        XCTAssertEqual(store.collapseStyle, .icons, "precondition: default seed")

        var emittedDuringSink: SidebarCollapseStyle?
        var storedPropertyDuringSink: SidebarCollapseStyle?
        var sinkFired = false

        store.$collapseStyle
            .dropFirst() // skip the initial replay of the current value
            .sink { emittedStyle in
                sinkFired = true
                emittedDuringSink = emittedStyle
                storedPropertyDuringSink = store.collapseStyle
            }
            .store(in: &cancellables)

        store.collapseStyle = .hidden

        XCTAssertTrue(sinkFired)
        XCTAssertEqual(emittedDuringSink, .hidden, "the emitted value is already the new one")
        XCTAssertEqual(
            storedPropertyDuringSink, .icons,
            "a synchronous re-read of the source property inside its own subscriber sees the OLD value -- "
                + "this is exactly why AppDelegate must use the emitted style, not re-read sidebarSettings.collapseStyle"
        )
    }

    func test_widthPlanner_fedTheEmittedValue_matchesWhatShouldBeAppliedImmediately() {
        let store = SidebarSettingsStore(root: tempDirectory)
        var appliedWidths: [CGFloat] = []

        store.$collapseStyle
            .dropFirst()
            .sink { emittedStyle in
                // Mirrors AppDelegate.applySidebarWidth's call, fed the
                // emitted value -- proving the fix, not just the bug.
                let width = SidebarWidthPlanner.width(
                    collapsed: true,
                    style: emittedStyle,
                    collapsedWidth: 56,
                    expandedWidth: 220
                )
                appliedWidths.append(width)
            }
            .store(in: &cancellables)

        store.collapseStyle = .hidden

        XCTAssertEqual(appliedWidths, [0], "fed the emitted value, the width collapses to zero immediately")
    }
}
