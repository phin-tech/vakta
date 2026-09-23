//
//  MultiplexerSetupModel.swift
//  Vakta
//
//  The shell for the tour's install step: checks PATH off the main actor,
//  publishes each tool's status, and hands install requests to the app
//  (which opens a transient installer session).
//

import Foundation

extension ExecutableSearch {
    /// `firstMatch` against the file system: a regular executable file, not
    /// a directory.
    static func locate(named name: String, inPATH path: String) -> String? {
        firstMatch(named: name, inPATH: path) { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: candidate)
        }
    }
}

@MainActor
final class MultiplexerSetupModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var tool: MultiplexerTool
        var status: MultiplexerInstallStatus
        var id: MultiplexerTool { tool }
    }

    /// Empty until the first check lands.
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isChecking = false

    private let pathProvider: () -> String
    private let install: (MultiplexerTool, String) -> Void
    private var generation = 0

    /// `pathProvider` is the user's resolved login-shell PATH (what sessions
    /// get), so a tool installed to e.g. ~/.local/bin is found.
    init(pathProvider: @escaping () -> String, install: @escaping (MultiplexerTool, String) -> Void) {
        self.pathProvider = pathProvider
        self.install = install
    }

    func refresh() {
        generation += 1
        let current = generation
        let path = pathProvider()
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let brew = ExecutableSearch.locate(named: "brew", inPATH: path)
            let rows = MultiplexerTool.allCases.map { tool in
                Row(tool: tool, status: MultiplexerSetupPlanner.status(
                    for: tool,
                    toolPath: ExecutableSearch.locate(named: tool.executableName, inPATH: path),
                    brewPath: brew
                ))
            }
            DispatchQueue.main.async { [weak self] in
                // A later refresh supersedes this one.
                guard let self, current == self.generation else { return }
                self.rows = rows
                self.isChecking = false
            }
        }
    }

    func install(_ tool: MultiplexerTool) {
        guard case .installable(let command) = rows.first(where: { $0.tool == tool })?.status else { return }
        install(tool, command)
    }
}
