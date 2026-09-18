//
//  PaletteAppendPlanner.swift
//  Vakta
//
//  Whether an asynchronously-fetched batch of palette items (e.g. a herdr
//  session's workspaces, fetched after the palette is already open) is still
//  meaningful to append -- `false` once the palette has been reset (closed
//  and reopened, or reset while the fetch was in flight) since it captured
//  its generation. The palette analog of `WorkspaceFetchPlanner`.
import Foundation

enum PaletteAppendPlanner {
    static func shouldApply(fetchGeneration: Int, currentGeneration: Int) -> Bool {
        fetchGeneration == currentGeneration
    }
}
