//
//  PaletteQuery.swift
//  Vakta
//
//  Pure parsing for the Cmd-K palette's query modes.

import Foundation

enum PaletteQueryMode: Equatable {
    case normal
    case allPanes
}

struct PaletteQuery: Equatable {
    let mode: PaletteQueryMode
    let text: String

    static func parse(_ raw: String) -> PaletteQuery {
        guard raw.first == "@" else {
            return PaletteQuery(mode: .normal, text: raw)
        }
        if raw.hasPrefix("@@") {
            return PaletteQuery(mode: .normal, text: String(raw.dropFirst()))
        }
        return PaletteQuery(mode: .allPanes, text: String(raw.dropFirst()))
    }
}
