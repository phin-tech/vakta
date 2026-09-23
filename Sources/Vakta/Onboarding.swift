//
//  Onboarding.swift
//  Vakta
//
//  Which first-run screen a launch shows: the welcome tour on a fresh
//  install, or What's New for releases since the last version the user
//  acknowledged. Pure decisions over value inputs -- the shell
//  (`OnboardingLaunch`) supplies the stored state, whether other settings
//  files already existed, the bundle version, and the release notes.
//

import Foundation

/// A semver-style marketing version: `major.minor[.patch][-prerelease]`,
/// optionally `v`-prefixed like the release tags. Ordered by semver rules
/// (a prerelease sorts before its release).
struct AppVersion: Hashable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ string: String) {
        var text = Substring(string)
        if text.first == "v" { text = text.dropFirst() }

        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(core.count) else { return nil }
        var numbers: [Int] = []
        for component in core {
            guard !component.isEmpty, component.allSatisfy(\.isASCIIDigit), let number = Int(component) else { return nil }
            numbers.append(number)
        }

        var prerelease: [String] = []
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            for identifier in identifiers {
                guard !identifier.isEmpty,
                      identifier.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" })
                else { return nil }
                prerelease.append(String(identifier))
            }
        }

        major = numbers[0]
        minor = numbers[1]
        patch = numbers.count == 3 ? numbers[2] : 0
        self.prerelease = prerelease
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}

struct WhatsNewHighlight: Equatable {
    /// An SF Symbol name.
    var symbolName: String
    var title: String
    var detail: String
}

struct ReleaseNote: Equatable {
    var version: AppVersion
    var highlights: [WhatsNewHighlight]
}

/// Persisted in `onboarding.json`. The file's existence records that
/// onboarding has run at least once; `lastSeenVersion` is the newest version
/// whose What's New the user has acknowledged (kept raw, so an unparseable
/// value is treated as unknown rather than failing the decode).
struct OnboardingState: Equatable, Codable {
    var lastSeenVersion: String?

    private enum CodingKeys: String, CodingKey {
        case lastSeenVersion
    }

    init(lastSeenVersion: String?) {
        self.lastSeenVersion = lastSeenVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSeenVersion = try container.decodeIfPresent(String.self, forKey: .lastSeenVersion)
    }
}

/// `onboarding.json` as the planner sees it. `unusable` is a corrupt or
/// unreadable file: show nothing and leave it for the user to inspect.
enum OnboardingStoredState: Equatable {
    case missing
    case loaded(OnboardingState)
    case unusable
}

enum OnboardingPresentation: Equatable {
    case none
    case tutorial
    /// Newest first.
    case whatsNew([ReleaseNote])
}

enum OnboardingPlanner {
    static let stateFileName = "onboarding.json"

    /// Fresh install -> the tour. Otherwise the notes after the last-seen
    /// version up to the running one, newest first; with no usable last-seen
    /// version (an upgrade from a build that predates onboarding), only the
    /// latest note up to the running one. An unknown running version (a
    /// SwiftPM dev build has no bundle version) never shows What's New.
    static func presentation(
        stored: OnboardingStoredState,
        priorInstallDetected: Bool,
        currentVersion: AppVersion?,
        releaseNotes: [ReleaseNote]
    ) -> OnboardingPresentation {
        let lastSeen: AppVersion?
        switch stored {
        case .unusable:
            return .none
        case .missing:
            if !priorInstallDetected { return .tutorial }
            lastSeen = nil
        case .loaded(let state):
            lastSeen = state.lastSeenVersion.flatMap(AppVersion.init)
        }
        guard let currentVersion else { return .none }

        let released = releaseHistory(currentVersion: currentVersion, releaseNotes: releaseNotes)
        let shown = lastSeen.map { seen in released.filter { $0.version > seen } } ?? Array(released.prefix(1))
        return shown.isEmpty ? .none : .whatsNew(shown)
    }

    /// Every note up to the running version, newest first -- what the
    /// on-demand What's New command shows. An unknown version (dev build)
    /// lists them all.
    static func releaseHistory(currentVersion: AppVersion?, releaseNotes: [ReleaseNote]) -> [ReleaseNote] {
        releaseNotes
            .filter { note in currentVersion.map { note.version <= $0 } ?? true }
            .sorted { $0.version > $1.version }
    }

    /// The state to persist once this launch's screen is acknowledged (or
    /// immediately, when there is none). Never moves `lastSeenVersion`
    /// backward, so running an older build doesn't reshow notes on return.
    static func recordedState(previous: OnboardingState?, currentVersion: AppVersion?) -> OnboardingState {
        guard let currentVersion else { return previous ?? OnboardingState(lastSeenVersion: nil) }
        if let previous,
           let seen = previous.lastSeenVersion.flatMap(AppVersion.init),
           seen > currentVersion {
            return previous
        }
        return OnboardingState(lastSeenVersion: currentVersion.description)
    }

    /// Whether Application Support already held other Vakta settings before
    /// this launch -- an upgrade from a build without onboarding, which
    /// should get What's New rather than the beginner tour.
    static func priorInstallDetected(existingFileNames: [String]) -> Bool {
        existingFileNames.contains { !$0.hasPrefix(".") && $0 != stateFileName }
    }
}

/// The shipping release notes. Add an entry per release that has something
/// worth telling existing users about; versions must be unique.
enum WhatsNewCatalog {
    static let releaseNotes: [ReleaseNote] = [
        ReleaseNote(version: AppVersion("0.1.0")!, highlights: [
            WhatsNewHighlight(
                symbolName: "command",
                title: "Leader keys",
                detail: "Turn on leader keys in Preferences, press the leader chord, and a hint panel shows every command one keystroke at a time."
            ),
            WhatsNewHighlight(
                symbolName: "magnifyingglass",
                title: "Find commands by their keys",
                detail: "The command palette now matches leader-key sequences as well as command names."
            ),
            WhatsNewHighlight(
                symbolName: "sidebar.right",
                title: "File sidebar",
                detail: "A right-hand tree of the focused pane's working directory. Toggle it from Appearance preferences or the command palette."
            ),
            WhatsNewHighlight(
                symbolName: "gearshape",
                title: "⌘, opens Preferences",
                detail: "The standard macOS shortcut now works out of the box, and can be rebound like any other."
            ),
        ]),
    ]
}
