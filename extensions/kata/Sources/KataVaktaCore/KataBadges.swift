//
//  KataBadges.swift
//  KataVaktaCore
//
//  Which issue a Session is working on, for its Session Badge: an open
//  issue id named in its branch (like `3kav-extensions`) wins; otherwise the
//  issue that Session was started on (the Session map).

import Foundation
import VaktaExtensionKit

public enum KataBadges {
    public static func issueID(branch: String?, sessionKey: SessionKey, map: KataSessionMap, openIDs: Set<String>) -> String? {
        let tokens = (branch ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if let named = tokens.first(where: openIDs.contains) { return named }
        if let started = map.issue(for: sessionKey), openIDs.contains(started) { return started }
        return nil
    }

    public static func badge(for issue: KataIssue, sessionKey: SessionKey) -> BadgeSetParams {
        var fields: [DetailView.Field] = []
        if let priority = issue.priority { fields.append(.init(label: "Priority", value: "P\(priority)")) }
        if let owner = issue.owner { fields.append(.init(label: "Owner", value: owner)) }
        return BadgeSetParams(
            sessionKey: sessionKey,
            text: issue.shortID,
            symbol: "circle.lefthalf.filled",
            popover: .detail(DetailView(title: "\(issue.shortID) · \(issue.title)", markdown: issue.body, fields: fields, buttons: []))
        )
    }

    /// The badge/set and badge/clear messages that move `previous` to `next`.
    public static func changes(from previous: [SessionKey: BadgeSetParams], to next: [SessionKey: BadgeSetParams]) -> [JSONRPCMessage] {
        var messages: [JSONRPCMessage] = []
        for (key, badge) in next where previous[key] != badge {
            if let params = try? ExtensionProtocolCodec.encode(badge) {
                messages.append(.notification(method: ProtocolMethod.badgeSet, params: params))
            }
        }
        for key in previous.keys where next[key] == nil {
            if let params = try? ExtensionProtocolCodec.encode(BadgeClearParams(sessionKey: key)) {
                messages.append(.notification(method: ProtocolMethod.badgeClear, params: params))
            }
        }
        return messages
    }
}
