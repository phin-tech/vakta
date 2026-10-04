//
//  ExtensionStatusItems.swift
//  Vakta
//
//  Pure decisions for Extension Status Items: each is one or more Status
//  Segments, placed leading (beside the branch) or trailing (right side),
//  ordered by link order, kept short, and able to ask for attention.

import Foundation
import VaktaExtensionKit

struct StatusBarSegment: Equatable, Identifiable {
    var index: Int
    var text: String
    var symbol: String?
    var tint: StatusSegment.Tint
    var help: String?
    var action: ViewButton?
    /// Only http(s); anything else is dropped.
    var url: URL?
    var popover: ViewDocument?
    var attention: Bool
    var id: Int { index }
}

struct StatusBarExtensionItem: Equatable, Identifiable {
    var extensionID: String
    var placement: StatusSetParams.Placement
    var segments: [StatusBarSegment]
    var id: String { extensionID }
}

/// Which segment's Popover or attention: Extension plus segment index.
struct StatusSegmentKey: Hashable {
    var extensionID: String
    var index: Int
}

enum ExtensionStatusItems {
    static let maxTextLength = 20
    static let maxSegments = 4

    /// Items for Extensions in `order` (link order); others are dropped, as
    /// are blank segments and items left with none.
    static func merge(_ items: [String: StatusSetParams], order: [String]) -> [StatusBarExtensionItem] {
        order.compactMap { id in
            guard let item = items[id] else { return nil }
            let segments = item.segments.compactMap { segment -> StatusSegment? in
                segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : segment
            }
            .prefix(maxSegments)
            .enumerated()
            .map { index, segment in
                StatusBarSegment(
                    index: index,
                    text: truncate(segment.text.trimmingCharacters(in: .whitespacesAndNewlines), to: maxTextLength),
                    symbol: segment.symbol,
                    tint: segment.tint,
                    help: segment.help,
                    action: segment.action,
                    url: segment.url.flatMap(safeURL),
                    popover: segment.popover,
                    attention: segment.attention
                )
            }
            guard !segments.isEmpty else { return nil }
            return StatusBarExtensionItem(extensionID: id, placement: item.placement, segments: segments)
        }
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Segments asking for attention.
    static func attention(_ items: [StatusBarExtensionItem]) -> Set<StatusSegmentKey> {
        Set(items.flatMap { item in
            item.segments.filter(\.attention).map { StatusSegmentKey(extensionID: item.extensionID, index: $0.index) }
        })
    }

    /// Whether a segment newly asks for attention (peek an Auto-hide bar).
    static func gainedAttention(from previous: [StatusBarExtensionItem], to current: [StatusBarExtensionItem]) -> Bool {
        !attention(current).subtracting(attention(previous)).isEmpty
    }

    private static func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }
}
