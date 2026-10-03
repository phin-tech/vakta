//
//  ExtensionStatusItems.swift
//  Vakta
//
//  Pure decisions for Extension Status Items: one per Extension, after the
//  built-in segments, in link order, with text kept short.

import Foundation
import VaktaExtensionKit

struct StatusBarExtensionItem: Equatable, Identifiable {
    var extensionID: String
    var text: String
    var symbol: String?
    var popover: ViewDocument?
    var id: String { extensionID }
}

enum ExtensionStatusItems {
    static let maxTextLength = 20

    /// Items for Extensions in `order` (link order); others are dropped.
    static func merge(_ items: [String: StatusSetParams], order: [String]) -> [StatusBarExtensionItem] {
        order.compactMap { id in
            guard let item = items[id] else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return StatusBarExtensionItem(
                extensionID: id, text: truncate(text, to: maxTextLength), symbol: item.symbol, popover: item.popover
            )
        }
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
