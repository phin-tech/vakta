//
//  HerdrConfigSearch.swift
//  Vakta
//
//  Pure search over the herdr config editor's catalogs. Every whitespace-
//  separated word of the query must appear (case-insensitively) somewhere in
//  an item's label, key path (also with `.`/`_` read as spaces, so "toast
//  delivery" finds `ui.toast.delivery`), help text, or group title. Key
//  actions also match their effective binding. Results keep catalog order.

import Foundation

enum HerdrConfigSearch {
    static func isActive(_ query: String) -> Bool {
        !words(query).isEmpty
    }

    static func settings(matching query: String) -> [HerdrConfigCatalog.Entry] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        return HerdrConfigCatalog.entries.filter { entry in
            matches(words, in: [entry.label, entry.path, spaced(entry.path), entry.help, entry.group.title])
        }
    }

    static func keyActions(matching query: String, in document: HerdrConfigDocument) -> [HerdrKeyAction] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        return HerdrKeyActionCatalog.actions.filter { action in
            let binding = HerdrKeyBindingState.resolve(action, in: document).binding
            return matches(words, in: [action.label, action.name, spaced(action.name), action.group.title, binding])
        }
    }

    private static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    private static func matches(_ words: [String], in fields: [String]) -> Bool {
        let haystack = fields.joined(separator: "\n").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}
