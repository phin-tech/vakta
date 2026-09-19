//
//  PaletteRootWorkspacePlanner.swift
//  Vakta
//
//  Pure selection of sessions whose workspace rows should be loaded into the
//  root Cmd-K palette.

import Foundation

struct PaletteWorkspaceSession: Equatable {
    let id: UUID
    let supportsWorkspaces: Bool
}

enum PaletteRootWorkspacePlanner {
    static func fetchSessionIDs(_ sessions: [PaletteWorkspaceSession]) -> [UUID] {
        sessions.filter(\.supportsWorkspaces).map(\.id)
    }
}
