//
//  OnboardingLaunch.swift
//  Vakta
//
//  The shell around `OnboardingPlanner`: reads Application Support and
//  `onboarding.json`, and records acknowledgement. `evaluate` must run
//  before `Stores` seeds its default settings files, or every launch would
//  look like an upgrade.
//

import Foundation

enum OnboardingPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<OnboardingState>> {
        PersistedFileStore(root: root, fileName: OnboardingPlanner.stateFileName, codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<OnboardingState> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ state: OnboardingState, root: URL) -> FileSaveOutcome {
        store(root: root).save(state)
    }
}

enum OnboardingLaunch {
    /// The running bundle's marketing version; nil for a SwiftPM dev build.
    static var bundleVersion: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    /// What this launch shows. When that's nothing, the current version is
    /// recorded now (so a later upgrade compares against it); a shown
    /// screen is recorded by `acknowledge` once dismissed, so quitting
    /// mid-tour shows it again.
    static func evaluate(root: URL, currentVersion: AppVersion?, releaseNotes: [ReleaseNote]) -> OnboardingPresentation {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let outcome = OnboardingPersistence.load(root: root)
        let stored = storedState(outcome)
        let presentation = OnboardingPlanner.presentation(
            stored: stored,
            priorInstallDetected: OnboardingPlanner.priorInstallDetected(existingFileNames: fileNames),
            currentVersion: currentVersion,
            releaseNotes: releaseNotes
        )
        if presentation == .none {
            record(outcome, currentVersion: currentVersion, root: root)
        }
        return presentation
    }

    /// Records that this launch's screen was seen. A corrupt or unreadable
    /// file is left untouched.
    static func acknowledge(root: URL, currentVersion: AppVersion?) {
        record(OnboardingPersistence.load(root: root), currentVersion: currentVersion, root: root)
    }

    private static func record(_ outcome: FileLoadOutcome<OnboardingState>, currentVersion: AppVersion?, root: URL) {
        let previous: OnboardingState?
        switch outcome {
        case .missing: previous = nil
        case .loaded(let state): previous = state
        case .corrupt, .unreadable: return
        }
        let next = OnboardingPlanner.recordedState(previous: previous, currentVersion: currentVersion)
        if next != previous {
            OnboardingPersistence.save(next, root: root)
        }
    }

    private static func storedState(_ outcome: FileLoadOutcome<OnboardingState>) -> OnboardingStoredState {
        switch outcome {
        case .missing: return .missing
        case .loaded(let state): return .loaded(state)
        case .corrupt, .unreadable: return .unusable
        }
    }
}
