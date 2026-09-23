//
//  PaletteMatcher.swift
//  Vakta
//
//  Filters the palette's flattened item list against the search query --
//  case-insensitive substring match on title or subtitle, generalizing
//  `SessionSwitcherModel`'s title-only match to cover a workspace row's
//  owning-session subtitle too, plus an exact match on a command row's
//  leader-key sequence. Pure.
import Foundation

enum PaletteMatcher {
    /// Whitespace-only query is treated as empty (shows everything), matching
    /// `SessionSwitcherModel.matches`'s existing contract.
    static func matches(query: String, in items: [PaletteItem]) -> [PaletteItem] {
        let parsed = PaletteQuery.parse(query)
        let candidates: [PaletteItem]
        switch parsed.mode {
        case .normal:
            candidates = items
        case .allPanes:
            candidates = items.filter { $0.category == .pane }
        }
        let q = parsed.text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return candidates }
        // A command whose whole leader sequence was typed ("of", "o f",
        // "tab n") ranks first; everything else keeps its order.
        let sequenceQuery = compacted(q)
        let bySequence = candidates.filter { $0.leaderSequence.map(compacted) == sequenceQuery }
        let sequenceIDs = Set(bySequence.map(\.id))
        let byText = candidates.filter {
            !sequenceIDs.contains($0.id)
                && ($0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false))
        }
        return bySequence + byText
    }

    /// Lowercased with all whitespace removed -- the form a leader sequence
    /// is compared in.
    private static func compacted(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }
}
