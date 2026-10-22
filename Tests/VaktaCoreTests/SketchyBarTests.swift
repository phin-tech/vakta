//
//  SketchyBarTests.swift
//  VaktaCoreTests
//
//  Core cases for the SketchyBar item: herdr.sh-style label and colour, the
//  argv that draws/removes it, when to resend, `--query bar` parsing, menu
//  placement under the bar, executable lookup, and `vakta://` routing.

import CoreGraphics
import XCTest
@testable import Vakta

final class SketchyBarItemPlannerTests: XCTestCase {
    func test_mixedStatuses_labelCountsNonZeroStatesInUrgencyOrder_andColoursByMostUrgent() {
        let appearance = SketchyBarItemPlanner.appearance(for: [.working, .attention, .done, .working, .idle])

        XCTAssertEqual(appearance, SketchyBarItemAppearance(iconColor: SketchyBarItemPlanner.attentionColor, label: "!1 ✓1 2"))
    }

    func test_doneAndWorking_colourDone() {
        XCTAssertEqual(
            SketchyBarItemPlanner.appearance(for: [.done, .done, .working]),
            SketchyBarItemAppearance(iconColor: SketchyBarItemPlanner.doneColor, label: "✓2 1")
        )
    }

    func test_onlyWorking_colourWorking() {
        XCTAssertEqual(
            SketchyBarItemPlanner.appearance(for: [.working]),
            SketchyBarItemAppearance(iconColor: SketchyBarItemPlanner.workingColor, label: "1")
        )
    }

    func test_idleUnknownAndUnavailable_dimWithNoLabel() {
        for statuses: [AgentStatus] in [[], [.idle], [.none, .unavailable, .idle]] {
            XCTAssertEqual(
                SketchyBarItemPlanner.appearance(for: statuses),
                SketchyBarItemAppearance(iconColor: SketchyBarItemPlanner.idleColor, label: nil),
                "\(statuses)"
            )
        }
    }
}

final class SketchyBarCommandTests: XCTestCase {
    func test_publish_addsIdempotentlyThenSetsEveryProperty() {
        let argv = SketchyBarCommand.publishArguments(
            SketchyBarItemAppearance(iconColor: "0xfff7768e", label: "!1 2")
        )

        XCTAssertEqual(argv, [
            "--add", "item", "vakta", "right",
            "--set", "vakta",
            "icon=\u{F018D}",
            "icon.color=0xfff7768e",
            "label=!1 2",
            "label.drawing=on",
            "click_script=open -g vakta://menu",
        ])
    }

    func test_publishWithoutLabel_hidesTheLabel() {
        let argv = SketchyBarCommand.publishArguments(SketchyBarItemAppearance(iconColor: "0x66ffffff", label: nil))

        XCTAssertTrue(argv.contains("label="))
        XCTAssertTrue(argv.contains("label.drawing=off"))
        XCTAssertFalse(argv.contains("label.drawing=on"))
    }

    func test_remove() {
        XCTAssertEqual(SketchyBarCommand.removeArguments, ["--remove", "vakta"])
    }
}

final class SketchyBarSyncPlannerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let busy = SketchyBarItemAppearance(iconColor: "0xffe0af68", label: "1")
    private let idle = SketchyBarItemAppearance(iconColor: "0x66ffffff", label: nil)

    func test_enabledAndNeverSent_publishes() {
        XCTAssertEqual(
            SketchyBarSyncPlanner.action(SketchyBarSyncState(), enabled: true, desired: busy, at: start),
            .publish(busy)
        )
    }

    func test_enabledAndUnchangedWithinInterval_doesNothing() {
        let state = SketchyBarSyncState(shown: busy, sentAt: start)
        let later = start.addingTimeInterval(SketchyBarSyncPlanner.reassertInterval - 1)

        XCTAssertEqual(SketchyBarSyncPlanner.action(state, enabled: true, desired: busy, at: later), .none)
    }

    func test_enabledAndUnchangedAtInterval_republishes() {
        let state = SketchyBarSyncState(shown: busy, sentAt: start)
        let later = start.addingTimeInterval(SketchyBarSyncPlanner.reassertInterval)

        XCTAssertEqual(SketchyBarSyncPlanner.action(state, enabled: true, desired: busy, at: later), .publish(busy))
    }

    func test_enabledAndChanged_publishesAtOnce() {
        let state = SketchyBarSyncState(shown: busy, sentAt: start)

        XCTAssertEqual(SketchyBarSyncPlanner.action(state, enabled: true, desired: idle, at: start), .publish(idle))
    }

    func test_disabledWhileShown_removes() {
        let state = SketchyBarSyncState(shown: busy, sentAt: start)

        XCTAssertEqual(SketchyBarSyncPlanner.action(state, enabled: false, desired: busy, at: start), .remove)
    }

    func test_disabledAndNothingShown_neverTouchesTheBar() {
        let later = start.addingTimeInterval(SketchyBarSyncPlanner.reassertInterval * 5)

        XCTAssertEqual(SketchyBarSyncPlanner.action(SketchyBarSyncState(), enabled: false, desired: busy, at: later), .none)
    }
}

final class SketchyBarGeometryTests: XCTestCase {
    func test_parsesRealQueryOutput() {
        // Trimmed from `sketchybar --query bar` (tab-indented, as it prints).
        let json = "{\n\t\"position\": \"top\",\n\t\"topmost\": \"on\",\n\t\"margin\": 0,\n\t\"height\": 40,\n\t\"y_offset\": 4,\n\t\"clip\": 0.00\n}"

        XCTAssertEqual(SketchyBarGeometry.parse(json), SketchyBarGeometry(position: .top, height: 40, yOffset: 4))
    }

    func test_bottomBar() {
        XCTAssertEqual(
            SketchyBarGeometry.parse(#"{"position":"bottom","height":28}"#),
            SketchyBarGeometry(position: .bottom, height: 28, yOffset: 0)
        )
    }

    func test_malformedOrMissingHeight_isNil() {
        XCTAssertNil(SketchyBarGeometry.parse("not json"))
        XCTAssertNil(SketchyBarGeometry.parse(#"{"position":"top"}"#))
        XCTAssertNil(SketchyBarGeometry.parse(#"{"position":"top","height":-5}"#))
    }
}

final class SketchyBarMenuPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func test_topBar_opensJustBelowTheBarAtThePointer() {
        let bar = SketchyBarGeometry(position: .top, height: 40, yOffset: 4)

        XCTAssertEqual(
            SketchyBarMenuPlacement.origin(mouseX: 1200, screenFrame: screen, bar: bar),
            CGPoint(x: 1200, y: 982 - 4 - 40)
        )
    }

    func test_bottomBar_opensJustAboveTheBar() {
        let bar = SketchyBarGeometry(position: .bottom, height: 28, yOffset: 0)

        XCTAssertEqual(
            SketchyBarMenuPlacement.origin(mouseX: 300, screenFrame: screen, bar: bar),
            CGPoint(x: 300, y: 28)
        )
    }

    func test_unknownBar_assumesATopBarOfFallbackHeight() {
        XCTAssertEqual(
            SketchyBarMenuPlacement.origin(mouseX: 10, screenFrame: screen, bar: nil),
            CGPoint(x: 10, y: 982 - SketchyBarMenuPlacement.fallbackBarHeight)
        )
    }

    func test_secondaryScreenOffset_isRespected() {
        let offset = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let bar = SketchyBarGeometry(position: .top, height: 40, yOffset: 0)

        XCTAssertEqual(
            SketchyBarMenuPlacement.origin(mouseX: 2000, screenFrame: offset, bar: bar),
            CGPoint(x: 2000, y: 880 - 40)
        )
    }
}

final class SketchyBarLocatorTests: XCTestCase {
    func test_firstExecutableCandidateWins() {
        let found = SketchyBarLocator.executable(candidates: ["/a", "/b", "/c"], isExecutable: { $0 != "/a" })

        XCTAssertEqual(found, "/b")
    }

    func test_noneExecutable_isNil() {
        XCTAssertNil(SketchyBarLocator.executable(candidates: SketchyBarLocator.candidates, isExecutable: { _ in false }))
    }
}

final class VaktaURLRouterTests: XCTestCase {
    func test_menu_showsTheMenu() throws {
        XCTAssertEqual(VaktaURLRouter.command(for: try XCTUnwrap(URL(string: "vakta://menu"))), .showMenu)
        XCTAssertEqual(VaktaURLRouter.command(for: try XCTUnwrap(URL(string: "VAKTA://Menu"))), .showMenu)
    }

    func test_unknownHostOrOtherScheme_isIgnored() throws {
        XCTAssertNil(VaktaURLRouter.command(for: try XCTUnwrap(URL(string: "vakta://quit"))))
        XCTAssertNil(VaktaURLRouter.command(for: try XCTUnwrap(URL(string: "https://menu"))))
    }
}

final class MenuBarSettingsCodecTests: XCTestCase {
    private func decode(_ json: String) throws -> MenuBarSettings? {
        JSONCodec<MenuBarSettings>().decode(Data(json.utf8))
    }

    func test_emptyFile_decodesDefaults_menuBarOnSketchyBarOff() throws {
        XCTAssertEqual(try decode("{}"), MenuBarSettings(showsMenuBarItem: true, showsSketchyBarItem: false))
    }

    func test_partialFile_defaultsTheMissingField() throws {
        XCTAssertEqual(
            try decode(#"{"showsSketchyBarItem":true}"#),
            MenuBarSettings(showsMenuBarItem: true, showsSketchyBarItem: true)
        )
    }

    func test_roundTrip() throws {
        let settings = MenuBarSettings(showsMenuBarItem: false, showsSketchyBarItem: true)
        let data = try XCTUnwrap(JSONCodec<MenuBarSettings>().encode(settings))

        XCTAssertEqual(JSONCodec<MenuBarSettings>().decode(data), settings)
    }
}
