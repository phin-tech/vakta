//
//  PaletteMatcher.swift
//  Vakta
//
//  Filters the palette's flattened item list against the search query --
//  case-insensitive substring match on title or subtitle, generalizing
//  `SessionSwitcherModel`'s title-only match to cover a workspace row's
//  owning-session subtitle too. Pure.
import Foundation

enum PaletteMatcher {
    /// Whitespace-only query is treated as empty (shows everything), matching
    /// `SessionSwitcherModel.matches`'s existing contract.
    static func matches(query: String, in items: [PaletteItem]) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }
}
