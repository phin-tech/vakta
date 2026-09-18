//
//  SidebarStateRestorationCombineTests.swift
//  VaktaIntegrationTests
//
//  Shell case proving the persisted collapsed state actually reaches the
//  width application on launch, against the real store and a real Combine
//  subscription. `AppDelegate` observes the store's `$isCollapsed` and applies
//  `SidebarWidthPlanner.width` on each emission; because `@Published` replays
//  its current value on subscribe, a sidebar saved collapsed must collapse on
//  the very first emission -- no 220px flash before it snaps shut. Mirrors
//  `SidebarWidthCombineTests`' approach: real store, real subscription, the
//  pure planner fed the emitted value. The divider position in a real
//  `NSSplitView` window stays a desktop-checklist check (testing.md).

import Combine
import XCTest
@testable import Vakta

@MainActor
final class SidebarStateRestorationCombineTests: XCTestCase {
    private var tempDirectory: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarStateRestorationCombineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func test_restoringCollapsedSidebar_appliesCollapsedWidthOnFirstEmission() {
        SidebarSettingsPersistence.save(
            SidebarSettings(collapseStyle: .icons, isCollapsed: true, expandedWidth: 300),
            root: tempDirectory
        )
        let store = SidebarSettingsStore(root: tempDirectory)

        var appliedWidths: [CGFloat] = []
        store.$isCollapsed
            .sink { collapsed in
                appliedWidths.append(
                    SidebarWidthPlanner.width(
                        collapsed: collapsed,
                        style: store.collapseStyle,
                        collapsedWidth: 56,
                        expandedWidth: store.expandedWidth
                    )
                )
            }
            .store(in: &cancellables)

        XCTAssertEqual(
            appliedWidths, [56],
            "a sidebar restored collapsed applies the icon-rail width immediately, never the expanded width first"
        )
    }

    func test_restoringExpandedSidebar_appliesThePersistedWidth() {
        SidebarSettingsPersistence.save(
            SidebarSettings(collapseStyle: .icons, isCollapsed: false, expandedWidth: 300),
            root: tempDirectory
        )
        let store = SidebarSettingsStore(root: tempDirectory)

        var appliedWidths: [CGFloat] = []
        store.$isCollapsed
            .sink { collapsed in
                appliedWidths.append(
                    SidebarWidthPlanner.width(
                        collapsed: collapsed,
                        style: store.collapseStyle,
                        collapsedWidth: 56,
                        expandedWidth: store.expandedWidth
                    )
                )
            }
            .store(in: &cancellables)

        XCTAssertEqual(appliedWidths, [300], "an expanded sidebar resumes at its saved width, not the 220 default")
    }
}
