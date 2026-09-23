//
//  OnboardingLaunchTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `OnboardingLaunch` against a temporary Application
//  Support root: what a launch presents, when `onboarding.json` is written
//  (immediately when nothing is shown, on acknowledgement otherwise), the
//  restart round trip, and a corrupt file left untouched.
//

import XCTest
@testable import Vakta

final class OnboardingLaunchTests: XCTestCase {
    private var root: URL!

    private let notes = [
        ReleaseNote(version: AppVersion("1.1.0")!, highlights: [WhatsNewHighlight(symbolName: "star", title: "A", detail: "a")]),
        ReleaseNote(version: AppVersion("1.2.0")!, highlights: [WhatsNewHighlight(symbolName: "star", title: "B", detail: "b")]),
    ]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingLaunchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var stateURL: URL { OnboardingPersistence.store(root: root).fileURL }

    private func evaluate(_ version: String?) -> OnboardingPresentation {
        OnboardingLaunch.evaluate(root: root, currentVersion: version.flatMap(AppVersion.init), releaseNotes: notes)
    }

    private func acknowledge(_ version: String?) {
        OnboardingLaunch.acknowledge(root: root, currentVersion: version.flatMap(AppVersion.init))
    }

    private func savedState() -> OnboardingState? {
        guard case .loaded(let state) = OnboardingPersistence.load(root: root) else { return nil }
        return state
    }

    func test_freshRoot_showsTutorial_andWritesNothingUntilAcknowledged() {
        XCTAssertEqual(evaluate("1.2.0"), .tutorial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))

        acknowledge("1.2.0")
        XCTAssertEqual(savedState(), OnboardingState(lastSeenVersion: "1.2.0"))
        XCTAssertEqual(evaluate("1.2.0"), OnboardingPresentation.none, "restart after the tour shows nothing")
    }

    func test_tutorialNotAcknowledged_isShownAgainNextLaunch() {
        XCTAssertEqual(evaluate("1.2.0"), .tutorial)
        XCTAssertEqual(evaluate("1.2.0"), .tutorial)
    }

    func test_existingInstall_showsLatestNote_thenNothingAfterAcknowledgeAndRestart() throws {
        try Data("{}".utf8).write(to: root.appendingPathComponent("workspace.json"))

        XCTAssertEqual(evaluate("1.2.0"), .whatsNew([notes[1]]))
        acknowledge("1.2.0")
        XCTAssertEqual(evaluate("1.2.0"), OnboardingPresentation.none)
    }

    func test_upgradeAfterAcknowledging_showsNewNotes() {
        acknowledge("1.0.0")
        XCTAssertEqual(evaluate("1.2.0"), .whatsNew([notes[1], notes[0]]))
    }

    func test_nothingToShow_recordsCurrentVersionImmediately() throws {
        try Data("{}".utf8).write(to: root.appendingPathComponent("workspace.json"))

        XCTAssertEqual(evaluate("1.0.0"), OnboardingPresentation.none)
        XCTAssertEqual(savedState(), OnboardingState(lastSeenVersion: "1.0.0"))
        XCTAssertEqual(evaluate("1.2.0"), .whatsNew([notes[1], notes[0]]), "a later upgrade compares against it")
    }

    func test_corruptState_showsNothing_andIsNeverOverwritten() throws {
        let corrupt = Data("{ not valid".utf8)
        try corrupt.write(to: stateURL)

        XCTAssertEqual(evaluate("1.2.0"), OnboardingPresentation.none)
        acknowledge("1.2.0")
        XCTAssertEqual(try Data(contentsOf: stateURL), corrupt)
    }
}
