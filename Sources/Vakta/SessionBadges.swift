//
//  SessionBadges.swift
//  Vakta
//
//  Pure decisions for Session Badges: at most one shows per Session row
//  (the first linked Extension with one), the rest are counted as `+N`, and
//  text stays short (the full text is the tooltip).

import Foundation
import VaktaExtensionKit

struct SessionBadge: Equatable, Identifiable {
    var extensionID: String
    var text: String
    var fullText: String
    var symbol: String?
    var popover: ViewDocument?
    var id: String { extensionID }
}

struct SessionBadgeDisplay: Equatable {
    var shown: SessionBadge
    /// How many more Extensions badge this row (`+N`).
    var hiddenCount: Int
    /// Every badge, in link order, for the `+N` Popover.
    var all: [SessionBadge]
}

enum SessionBadges {
    static let maxTextLength = 8

    static func display(
        for sessionKey: SessionKey, badges: [String: [SessionKey: BadgeSetParams]], order: [String]
    ) -> SessionBadgeDisplay? {
        let all = order.compactMap { id -> SessionBadge? in
            guard let params = badges[id]?[sessionKey] else { return nil }
            let text = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SessionBadge(
                extensionID: id, text: ExtensionStatusItems.truncate(text, to: maxTextLength), fullText: text,
                symbol: params.symbol, popover: params.popover
            )
        }
        guard let first = all.first else { return nil }
        return SessionBadgeDisplay(shown: first, hiddenCount: all.count - 1, all: all)
    }
}
