//
//  MultiplexerSetup.swift
//  Vakta
//
//  The welcome tour's "install herdr and tmux" step: which tools are
//  installed, the official install command for each that isn't, and the
//  transient session profile that runs it. Pure decisions -- the shell
//  (`MultiplexerSetupModel`) supplies what's on PATH.
//

import Foundation

enum MultiplexerTool: CaseIterable, Hashable {
    case herdr
    case tmux

    var executableName: String {
        switch self {
        case .herdr: return "herdr"
        case .tmux: return "tmux"
        }
    }
}

enum MultiplexerInstallStatus: Equatable {
    case installed(path: String)
    /// A shell command line to run in a terminal.
    case installable(command: String)
    /// tmux has no official macOS binary; Homebrew is the supported route.
    case needsHomebrew
}

enum ExecutableSearch {
    /// The first `directory/name` on `path` (a `PATH` value) that
    /// `isExecutable` accepts. Empty and relative entries are skipped: a
    /// relative entry would resolve against Vakta's own working directory.
    static func firstMatch(named name: String, inPATH path: String, isExecutable: (String) -> Bool) -> String? {
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = directory.hasSuffix("/") ? "\(directory)\(name)" : "\(directory)/\(name)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

enum MultiplexerSetupPlanner {
    static let herdrInstallScript = "curl -fsSL https://herdr.dev/install.sh | sh"
    static let homebrewURL = URL(string: "https://brew.sh")!

    /// Installed wins. Otherwise Homebrew when present (`brew install
    /// herdr` / `brew install tmux`); without it, herdr's official install
    /// script, and tmux needs Homebrew first.
    static func status(for tool: MultiplexerTool, toolPath: String?, brewPath: String?) -> MultiplexerInstallStatus {
        if let toolPath { return .installed(path: toolPath) }
        if brewPath != nil { return .installable(command: "brew install \(tool.executableName)") }
        switch tool {
        case .herdr: return .installable(command: herdrInstallScript)
        case .tmux: return .needsHomebrew
        }
    }

    /// A one-off plain-shell session that echoes and runs `installCommand`,
    /// reports the outcome, and closes on Return. The script is a single
    /// quoted `/bin/sh -c` argument. The caller must create the session as
    /// transient, so it is never saved to the workspace.
    static func installerProfile(for tool: MultiplexerTool, installCommand: String, id: UUID) -> Profile {
        let name = tool.executableName
        let script = [
            "printf '%s\\n' \(LaunchCommandPlanner.shellQuote("$ " + installCommand))",
            installCommand,
            "status=$?",
            "echo",
            "if [ \"$status\" -eq 0 ]; then echo '\(name) is installed. Press Return to close this session.'; "
                + "else echo \"Install failed (exit $status). Press Return to close this session.\"; fi",
            "read -r _",
        ].joined(separator: "; ")
        return Profile(
            id: id,
            name: "Install \(name)",
            command: "/bin/sh",
            arguments: "-c " + LaunchCommandPlanner.shellQuote(script)
        )
    }
}
