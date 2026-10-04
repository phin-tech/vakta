//
//  GitHubViews.swift
//  GitHubCore
//
//  What the GitHub Extension shows: the status bar (the focused pane's
//  branch and PR, and a summary of every PR in your panes), notifications
//  when a PR changes state, and the shared look of a PR (symbol and tint).

import Foundation
import VaktaExtensionKit

/// One pane on a PR branch.
public struct PullRequestPlacement: Equatable, Sendable {
    public var sessionKey: SessionKey
    public var sessionFocused: Bool
    public var pane: PaneContext
    public var target: PullRequestTarget
    public var pullRequest: PullRequest?

    public init(sessionKey: SessionKey, sessionFocused: Bool, pane: PaneContext, target: PullRequestTarget, pullRequest: PullRequest?) {
        self.sessionKey = sessionKey
        self.sessionFocused = sessionFocused
        self.pane = pane
        self.target = target
        self.pullRequest = pullRequest
    }
}

public enum GitHubLook {
    public static func symbol(_ state: PullRequestState) -> String {
        switch state {
        case .failing: return "xmark.circle.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .pending: return "clock.fill"
        case .passing: return "checkmark.circle"
        case .readyToMerge: return "checkmark.circle.fill"
        case .noChecks: return "arrow.triangle.pull"
        }
    }

    /// Green stays reserved for "ready to merge".
    public static func tint(_ state: PullRequestState) -> StatusSegment.Tint {
        switch state {
        case .failing, .changesRequested: return .failure
        case .pending: return .warning
        case .readyToMerge: return .success
        case .passing, .noChecks: return .neutral
        }
    }

    public static func describe(_ state: PullRequestState) -> String {
        switch state {
        case .failing: return "checks failing"
        case .changesRequested: return "changes requested"
        case .pending: return "checks pending"
        case .passing: return "checks passing, not mergeable yet"
        case .readyToMerge: return "ready to merge"
        case .noChecks: return "no checks"
        }
    }

    public static func checkSymbol(_ state: PullRequestCheck.State) -> String {
        switch state {
        case .failing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .passing: return "checkmark.circle"
        }
    }

    /// Opens a URL from a Popover row or panel button.
    public static func openButton(_ url: String, title: String = "Open") -> ViewButton {
        ViewButton(title: title, symbol: "safari", callback: GitHubCallbacks.openURL, payload: .object(["url": .string(url)]),
                   style: .default, confirm: nil, shortcut: nil)
    }
}

public enum GitHubCallbacks {
    public static let openURL = "open-url"
}

public enum GitHubStatus {
    /// The focused Session's focused pane.
    public static func focusedPane(_ contexts: [ExtensionContext]) -> PaneContext? {
        contexts.first(where: \.focused)?.panes?.first(where: \.focused)
    }

    /// Distinct PRs across placements, worst first, then by number.
    public static func distinct(_ placements: [PullRequestPlacement]) -> [PullRequest] {
        var seen = Set<String>()
        return placements.compactMap(\.pullRequest).filter { seen.insert($0.url).inserted }
            .sorted { ($0.state, $0.number) < ($1.state, $1.number) }
    }

    /// The status bar. `attention` lists PR URLs that just changed into a
    /// state worth a look (peek once).
    public static func statusItem(
        contexts: [ExtensionContext], placements: [PullRequestPlacement], attention: Set<String> = []
    ) -> StatusSetParams? {
        var segments: [StatusSegment] = []
        let focused = focusedPane(contexts)
        if let branch = focused?.branch {
            segments.append(StatusSegment(text: branch, symbol: "arrow.triangle.branch", help: "Current branch"))
        }
        let focusedPR = focused.flatMap { pane in placements.first { $0.pane.paneID == pane.paneID }?.pullRequest }
        if let pr = focusedPR {
            segments.append(StatusSegment(
                text: "#\(pr.number)", symbol: symbol(pr), tint: GitHubLook.tint(pr.state),
                help: "\(pr.isDraft ? "Draft · " : "")#\(pr.number) \(pr.title) — \(GitHubLook.describe(pr.state)). Click to open.",
                url: pr.url, attention: attention.contains(pr.url)
            ))
            if !pr.checks.isEmpty {
                segments.append(StatusSegment(
                    text: "\(pr.passing)/\(pr.checks.count)", help: "\(pr.passing) of \(pr.checks.count) checks passing",
                    popover: checksPopover(pr)
                ))
            }
        }
        let all = distinct(placements)
        if all.contains(where: { $0.url != focusedPR?.url }), let worst = all.first {
            segments.append(StatusSegment(
                text: all.count == 1 ? "1 PR" : "\(all.count) PRs", symbol: GitHubLook.symbol(worst.state),
                tint: GitHubLook.tint(worst.state), help: "Pull requests across all sessions",
                popover: listPopover(placements), attention: all.contains { attention.contains($0.url) && $0.url != focusedPR?.url },
                placement: .trailing
            ))
        }
        return segments.isEmpty ? nil : StatusSetParams(placement: .leading, segments: segments)
    }

    private static func symbol(_ pr: PullRequest) -> String { GitHubLook.symbol(pr.state) }

    static func checksPopover(_ pr: PullRequest) -> ViewDocument {
        .list(ListView(title: "#\(pr.number) \(pr.title)", searchPlaceholder: nil, emptyText: "No checks", sections: [
            ListSection(title: "Checks", items: pr.orderedChecks.enumerated().map { index, check in
                ListItem(id: "check-\(index)", title: check.name, subtitle: nil, symbol: GitHubLook.checkSymbol(check.state),
                         accessories: [], detail: nil, buttons: check.url.map { [GitHubLook.openButton($0)] } ?? [])
            }),
        ]))
    }

    /// Every PR grouped by `session › workspace`, the focused Session first.
    static func listPopover(_ placements: [PullRequestPlacement]) -> ViewDocument {
        var groups: [(title: String, focused: Bool, prs: [PullRequest])] = []
        for placement in placements {
            guard let pr = placement.pullRequest else { continue }
            let title = [placement.sessionKey.sessionName, placement.pane.workspace?.label].compactMap { $0 }.joined(separator: " › ")
            if let index = groups.firstIndex(where: { $0.title == title }) {
                if !groups[index].prs.contains(where: { $0.url == pr.url }) { groups[index].prs.append(pr) }
            } else {
                groups.append((title, placement.sessionFocused, [pr]))
            }
        }
        let ordered = groups.filter(\.focused) + groups.filter { !$0.focused }
        return .list(ListView(title: nil, searchPlaceholder: nil, emptyText: "No pull requests", sections: ordered.map { group in
            ListSection(title: group.title, items: group.prs.sorted { ($0.state, $0.number) < ($1.state, $1.number) }.map { pr in
                ListItem(id: pr.url, title: "#\(pr.number) \(pr.title)", subtitle: GitHubLook.describe(pr.state),
                         symbol: GitHubLook.symbol(pr.state), accessories: [], detail: nil, buttons: [GitHubLook.openButton(pr.url)])
            })
        }))
    }
}

public enum GitHubNotices {
    /// PRs that moved into failing, changes requested or ready to merge
    /// since the previous result (never on first observation).
    public static func transitions(previous: [String: PullRequestState], current: [PullRequest]) -> [PullRequest] {
        current.filter { pr in
            guard let before = previous[pr.url], before != pr.state else { return false }
            return [.failing, .changesRequested, .readyToMerge].contains(pr.state)
        }
    }

    public static func notice(for pr: PullRequest, sessionKey: SessionKey?) -> NotifyParams {
        let title: String
        switch pr.state {
        case .failing: title = "Checks failing on #\(pr.number)"
        case .changesRequested: title = "Changes requested on #\(pr.number)"
        case .readyToMerge: title = "#\(pr.number) is ready to merge"
        default: title = "#\(pr.number) changed"
        }
        return NotifyParams(title: title, body: pr.title, sessionKey: sessionKey)
    }
}
