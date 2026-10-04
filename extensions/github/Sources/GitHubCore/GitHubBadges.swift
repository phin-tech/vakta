//
//  GitHubBadges.swift
//  GitHubCore
//
//  A Session Badge per Session with PRs: its focused pane's PR, else its
//  worst-state PR; the badge's Popover lists the Session's PRs.

import Foundation
import VaktaExtensionKit

public enum GitHubBadges {
    public static func badges(_ placements: [PullRequestPlacement]) -> [SessionKey: BadgeSetParams] {
        var bySession: [SessionKey: [PullRequestPlacement]] = [:]
        for placement in placements where placement.pullRequest != nil {
            bySession[placement.sessionKey, default: []].append(placement)
        }
        return bySession.compactMapValues { sessionPlacements -> BadgeSetParams? in
            let prs = GitHubStatus.distinct(sessionPlacements)
            guard let shown = sessionPlacements.first(where: \.pane.focused)?.pullRequest ?? prs.first else { return nil }
            let rows = prs.map { pr in
                ListItem(id: pr.url, title: "#\(pr.number) \(pr.title)", subtitle: GitHubLook.describe(pr.state),
                         symbol: GitHubLook.symbol(pr.state), accessories: [], detail: nil, buttons: [GitHubLook.openButton(pr.url)])
            }
            return BadgeSetParams(
                sessionKey: sessionPlacements[0].sessionKey, text: "#\(shown.number)", symbol: GitHubLook.symbol(shown.state),
                tint: GitHubLook.tint(shown.state),
                popover: .list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [ListSection(title: "Pull requests", items: rows)]))
            )
        }
    }

    /// The badge/set and badge/clear messages that move `previous` to `next`.
    public static func changes(from previous: [SessionKey: BadgeSetParams], to next: [SessionKey: BadgeSetParams]) -> [JSONRPCMessage] {
        var messages: [JSONRPCMessage] = []
        for (key, badge) in next where previous[key] != badge {
            if let params = try? ExtensionProtocolCodec.encode(badge) { messages.append(.notification(method: ProtocolMethod.badgeSet, params: params)) }
        }
        for key in previous.keys where next[key] == nil {
            if let params = try? ExtensionProtocolCodec.encode(BadgeClearParams(sessionKey: key)) {
                messages.append(.notification(method: ProtocolMethod.badgeClear, params: params))
            }
        }
        return messages
    }
}
