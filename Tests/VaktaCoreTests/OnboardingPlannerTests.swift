//
//  OnboardingPlannerTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `OnboardingPlanner`: which screen (tutorial,
//  What's New, or none) a launch shows, the state recorded once it's
//  acknowledged, and how a prior install is recognized. Release notes here
//  are fixtures, not the shipping catalog.
//

import XCTest
@testable import Vakta

final class OnboardingPlannerTests: XCTestCase {
    private func v(_ string: String) -> AppVersion { AppVersion(string)! }

    private func note(_ version: String) -> ReleaseNote {
        ReleaseNote(version: v(version), highlights: [
            WhatsNewHighlight(symbolName: "star", title: "In \(version)", detail: "Detail")
        ])
    }

    private func present(
        _ stored: OnboardingStoredState,
        prior: Bool = true,
        current: String?,
        notes: [String]
    ) -> OnboardingPresentation {
        OnboardingPlanner.presentation(
            stored: stored,
            priorInstallDetected: prior,
            currentVersion: current.map(v),
            releaseNotes: notes.map(note)
        )
    }

    private func loaded(_ lastSeen: String?) -> OnboardingStoredState {
        .loaded(OnboardingState(lastSeenVersion: lastSeen))
    }

    // MARK: Fresh install

    func test_freshInstall_showsTutorial() {
        XCTAssertEqual(present(.missing, prior: false, current: "1.2.0", notes: ["1.2.0"]), .tutorial)
    }

    func test_freshInstall_withUnknownVersion_stillShowsTutorial() {
        XCTAssertEqual(present(.missing, prior: false, current: nil, notes: []), .tutorial)
    }

    // MARK: Upgrade from a build that predates onboarding

    func test_priorInstallWithoutState_showsOnlyTheLatestNoteUpToCurrent() {
        XCTAssertEqual(
            present(.missing, current: "1.2.0", notes: ["1.0.0", "1.1.0", "1.2.0", "1.3.0"]),
            .whatsNew([note("1.2.0")])
        )
    }

    func test_priorInstallWithoutState_andNoApplicableNotes_showsNothing() {
        XCTAssertEqual(present(.missing, current: "1.2.0", notes: ["1.3.0"]), OnboardingPresentation.none)
        XCTAssertEqual(present(.missing, current: "1.2.0", notes: []), OnboardingPresentation.none)
    }

    // MARK: Upgrade with a recorded last-seen version

    func test_upgrade_showsNotesAfterLastSeenThroughCurrent_newestFirst() {
        XCTAssertEqual(
            present(loaded("1.0.0"), current: "1.2.0", notes: ["1.0.0", "1.1.0", "1.2.0", "1.3.0"]),
            .whatsNew([note("1.2.0"), note("1.1.0")])
        )
    }

    func test_upgrade_ordersNewestFirst_evenWhenCatalogIsUnsorted() {
        XCTAssertEqual(
            present(loaded("1.0.0"), current: "1.2.0", notes: ["1.2.0", "1.1.0", "1.1.5"]),
            .whatsNew([note("1.2.0"), note("1.1.5"), note("1.1.0")])
        )
    }

    func test_upgrade_withNoNotesInRange_showsNothing() {
        XCTAssertEqual(present(loaded("1.1.0"), current: "1.1.5", notes: ["1.1.0", "1.2.0"]), OnboardingPresentation.none)
    }

    func test_sameVersion_showsNothing() {
        XCTAssertEqual(present(loaded("1.2.0"), current: "1.2.0", notes: ["1.2.0"]), OnboardingPresentation.none)
    }

    func test_downgrade_showsNothing() {
        XCTAssertEqual(present(loaded("1.3.0"), current: "1.2.0", notes: ["1.2.0", "1.3.0"]), OnboardingPresentation.none)
    }

    func test_prereleaseCurrent_excludesTheFinalReleaseNote_butIncludesItsOwn() {
        XCTAssertEqual(present(loaded("1.1.0"), current: "1.2.0-beta.1", notes: ["1.2.0"]), OnboardingPresentation.none)
        XCTAssertEqual(
            present(loaded("1.1.0"), current: "1.2.0-beta.1", notes: ["1.2.0-beta.1", "1.2.0"]),
            .whatsNew([note("1.2.0-beta.1")])
        )
    }

    func test_recordedStateWithoutLastSeen_showsOnlyTheLatestNoteUpToCurrent() {
        XCTAssertEqual(present(loaded(nil), current: "1.2.0", notes: ["1.1.0", "1.2.0"]), .whatsNew([note("1.2.0")]))
    }

    func test_unparseableLastSeen_isTreatedAsUnknown() {
        XCTAssertEqual(present(loaded("garbage"), current: "1.2.0", notes: ["1.1.0", "1.2.0"]), .whatsNew([note("1.2.0")]))
    }

    func test_recordedState_neverReshowsTheTutorial() {
        XCTAssertEqual(present(loaded("1.2.0"), prior: false, current: "1.2.0", notes: []), OnboardingPresentation.none)
    }

    // MARK: Unknown version / unusable state

    func test_unknownCurrentVersion_neverShowsWhatsNew() {
        XCTAssertEqual(present(loaded("1.0.0"), current: nil, notes: ["1.2.0"]), OnboardingPresentation.none)
        XCTAssertEqual(present(.missing, current: nil, notes: ["1.2.0"]), OnboardingPresentation.none)
    }

    func test_unusableState_showsNothing() {
        XCTAssertEqual(present(.unusable, prior: false, current: "1.2.0", notes: ["1.2.0"]), OnboardingPresentation.none)
    }

    // MARK: Recorded state

    func test_recordedState_storesNormalizedCurrentVersion() {
        XCTAssertEqual(
            OnboardingPlanner.recordedState(previous: nil, currentVersion: v("v1.2")),
            OnboardingState(lastSeenVersion: "1.2.0")
        )
    }

    func test_recordedState_advancesPastAnOlderLastSeen() {
        XCTAssertEqual(
            OnboardingPlanner.recordedState(previous: OnboardingState(lastSeenVersion: "1.0.0"), currentVersion: v("1.2.0")),
            OnboardingState(lastSeenVersion: "1.2.0")
        )
    }

    func test_recordedState_keepsANewerLastSeen_soADowngradeDoesNotReshowNotes() {
        XCTAssertEqual(
            OnboardingPlanner.recordedState(previous: OnboardingState(lastSeenVersion: "1.3.0"), currentVersion: v("1.2.0")),
            OnboardingState(lastSeenVersion: "1.3.0")
        )
    }

    func test_recordedState_replacesAnUnparseableLastSeen() {
        XCTAssertEqual(
            OnboardingPlanner.recordedState(previous: OnboardingState(lastSeenVersion: "garbage"), currentVersion: v("1.2.0")),
            OnboardingState(lastSeenVersion: "1.2.0")
        )
    }

    func test_recordedState_withUnknownCurrentVersion_keepsPrevious() {
        XCTAssertEqual(
            OnboardingPlanner.recordedState(previous: OnboardingState(lastSeenVersion: "1.0.0"), currentVersion: nil),
            OnboardingState(lastSeenVersion: "1.0.0")
        )
        XCTAssertEqual(
            OnboardingPlanner.recordedState(previous: nil, currentVersion: nil),
            OnboardingState(lastSeenVersion: nil)
        )
    }

    // MARK: On-demand What's New

    func test_releaseHistory_listsNotesUpToCurrent_newestFirst() {
        XCTAssertEqual(
            OnboardingPlanner.releaseHistory(currentVersion: v("1.1.0"), releaseNotes: ["1.0.0", "1.2.0", "1.1.0"].map(note)),
            [note("1.1.0"), note("1.0.0")]
        )
    }

    func test_releaseHistory_withUnknownVersion_listsEveryNote() {
        XCTAssertEqual(
            OnboardingPlanner.releaseHistory(currentVersion: nil, releaseNotes: ["1.0.0", "1.2.0"].map(note)),
            [note("1.2.0"), note("1.0.0")]
        )
    }

    // MARK: Prior install detection

    func test_priorInstall_emptyDirectory_isFresh() {
        XCTAssertFalse(OnboardingPlanner.priorInstallDetected(existingFileNames: []))
    }

    func test_priorInstall_onlyOnboardingOrHiddenFiles_isFresh() {
        XCTAssertFalse(OnboardingPlanner.priorInstallDetected(existingFileNames: ["onboarding.json", ".DS_Store"]))
    }

    func test_priorInstall_anyOtherSettingsFile_isPrior() {
        XCTAssertTrue(OnboardingPlanner.priorInstallDetected(existingFileNames: ["workspace.json"]))
        XCTAssertTrue(OnboardingPlanner.priorInstallDetected(existingFileNames: [".DS_Store", "keybindings.json"]))
    }

    // MARK: Shipping catalog

    func test_shippingCatalog_versionsParseAreUniqueAndEachHasHighlights() {
        let notes = WhatsNewCatalog.releaseNotes
        XCTAssertFalse(notes.isEmpty)
        XCTAssertEqual(Set(notes.map(\.version)).count, notes.count, "duplicate release-note version")
        for note in notes {
            XCTAssertFalse(note.highlights.isEmpty, "\(note.version) has no highlights")
        }
    }
}
