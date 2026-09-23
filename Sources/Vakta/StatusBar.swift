//
//  StatusBar.swift
//  Vakta
//
//  The status bar under the terminal: its visibility preference and the pure
//  decisions for what it shows. Deliberately minimal -- the focused pane's
//  branch, one PR glyph, and a count of other PRs in the session that need
//  attention; nothing renders without data.
//

import Foundation

enum StatusBarVisibility: String, Codable, CaseIterable {
    /// Docked only while there is something to show.
    case auto
    /// Hidden until hovered at the terminal's bottom edge (Dock-style);
    /// overlays the terminal, so it never resizes it.
    case autoHide
    /// Always docked, empty or not.
    case show
    /// Never shown; PR lookups are skipped.
    case hide

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .autoHide: return "Auto-hide"
        case .show: return "Always"
        case .hide: return "Never"
        }
    }

    /// The "Cycle Status Bar Visibility" command's order.
    var next: StatusBarVisibility {
        switch self {
        case .auto: return .autoHide
        case .autoHide: return .show
        case .show: return .hide
        case .hide: return .auto
        }
    }

    var needsPullRequestStatus: Bool { self != .hide }
}

struct StatusBarPreferences: Equatable {
    var visibility: StatusBarVisibility = .auto
}

extension StatusBarPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case visibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown mode (a newer build's) is a view preference, not data
        // worth rejecting the file over.
        visibility = (try? container.decodeIfPresent(StatusBarVisibility.self, forKey: .visibility)) ?? .auto
    }
}

enum StatusBarPreferencesPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<StatusBarPreferences>> {
        PersistedFileStore(root: root, fileName: "status-bar.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<StatusBarPreferences> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ preferences: StatusBarPreferences, root: URL) -> FileSaveOutcome {
        store(root: root).save(preferences)
    }
}

/// Source of truth for the status bar's visibility; each change is persisted
/// immediately (a corrupt file falls back to the default for this run only
/// and is not overwritten -- see `PersistedFileStore`).
@MainActor
final class StatusBarPreferencesStore: ObservableObject {
    @Published var visibility: StatusBarVisibility { didSet { persist() } }

    private let root: URL

    init(root: URL) {
        self.root = root
        let outcome = StatusBarPreferencesPersistence.load(root: root)
        switch outcome {
        case .loaded(let preferences): visibility = preferences.visibility
        case .missing, .corrupt, .unreadable: visibility = StatusBarPreferences().visibility
        }
        if case .missing = outcome {
            persist()
        }
    }

    func cycle() {
        visibility = visibility.next
    }

    private func persist() {
        StatusBarPreferencesPersistence.save(StatusBarPreferences(visibility: visibility), root: root)
    }
}

/// The single state glyph shown next to a PR number.
enum StatusBarGlyph: Equatable {
    case failing
    case changesRequested
    case pending
    case passing
    /// No checks and no decisive review yet.
    case noChecks
}

struct StatusBarPullRequest: Equatable {
    let number: Int
    let url: String
    let title: String
    let isDraft: Bool
    let glyph: StatusBarGlyph
}

struct StatusBarContent: Equatable {
    var branch: String?
    var pullRequest: StatusBarPullRequest?
    /// Other PRs in the selected session with failing checks or changes
    /// requested; 0 hides the indicator.
    var attentionElsewhere: Int

    var isEmpty: Bool { branch == nil && pullRequest == nil && attentionElsewhere == 0 }
}

enum StatusBarPresentation {
    /// `workspaceSummaries` are the selected session's. A PR open in panes
    /// of several workspaces is counted once per workspace -- an accepted
    /// overcount for a rare layout.
    static func content(
        focused: FocusedPullRequestState?,
        workspaceSummaries: [String: PullRequestSummary]
    ) -> StatusBarContent {
        let total = workspaceSummaries.values.reduce(0) { $0 + $1.needingAttention }
        let focusedNeedsAttention = focused?.pullRequest?.needsAttention == true
        return StatusBarContent(
            branch: focused?.target.branch,
            pullRequest: focused?.pullRequest.map { pullRequest in
                StatusBarPullRequest(
                    number: pullRequest.number,
                    url: pullRequest.url,
                    title: pullRequest.title,
                    isDraft: pullRequest.isDraft,
                    glyph: glyph(for: pullRequest)
                )
            },
            attentionElsewhere: max(0, total - (focusedNeedsAttention ? 1 : 0))
        )
    }

    /// Worst first: failing checks, changes requested, pending checks, then
    /// passing checks or an approval.
    static func glyph(for pullRequest: PullRequestStatus) -> StatusBarGlyph {
        if pullRequest.checks.state == .failing { return .failing }
        if pullRequest.review == .changesRequested { return .changesRequested }
        if pullRequest.checks.state == .pending { return .pending }
        if pullRequest.checks.state == .passing || pullRequest.review == .approved { return .passing }
        return .noChecks
    }

    /// Whether the bar takes space under the terminal. Auto-hide never docks:
    /// it overlays the terminal while revealed.
    static func isDocked(_ visibility: StatusBarVisibility, content: StatusBarContent) -> Bool {
        switch visibility {
        case .show: return true
        case .hide, .autoHide: return false
        case .auto: return !content.isEmpty
        }
    }
}
