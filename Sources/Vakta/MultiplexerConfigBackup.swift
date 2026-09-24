//
//  MultiplexerConfigBackup.swift
//  Vakta
//
//  Before the Mac-style shortcuts are applied, copy the user's tmux and
//  herdr configs into Vakta's storage. The preset never edits them -- its
//  chords live in Vakta's keybindings -- so this is a safety net and a
//  snapshot to tune from. `MultiplexerConfigBackupPlanner` decides what to
//  copy (pure); `MultiplexerConfigBackup` does the copying.
//

import Foundation

struct MultiplexerConfigBackupFile: Equatable {
    /// The config's path; a symlink is copied as its target's contents.
    let source: String
    /// The copy's file name inside the backup folder.
    let name: String
}

struct MultiplexerConfigBackupPlan: Equatable {
    let folderName: String
    let files: [MultiplexerConfigBackupFile]
}

enum MultiplexerConfigBackupPlanner {
    /// `~/.tmux.conf`, the XDG tmux config (`$XDG_CONFIG_HOME/tmux/tmux.conf`,
    /// else `~/.config/tmux/tmux.conf`), and the herdr config wherever
    /// `HerdrConfigLocator` resolves it -- whichever exist. Nil when none do.
    static func plan(
        home: URL,
        environment: [String: String],
        now: Date,
        timeZone: TimeZone = .current,
        fileExists: (String) -> Bool
    ) -> MultiplexerConfigBackupPlan? {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let candidates = [
            MultiplexerConfigBackupFile(source: home.appendingPathComponent(".tmux.conf").path, name: "dot-tmux.conf"),
            MultiplexerConfigBackupFile(
                source: configHome.appendingPathComponent("tmux", isDirectory: true).appendingPathComponent("tmux.conf").path,
                name: "tmux.conf"
            ),
            MultiplexerConfigBackupFile(source: HerdrConfigLocator.resolve(environment: environment, home: home).path, name: "herdr-config.toml"),
        ]
        let files = candidates.filter { fileExists($0.source) }
        guard !files.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return MultiplexerConfigBackupPlan(folderName: "mac-shortcuts-\(formatter.string(from: now))", files: files)
    }
}

enum MultiplexerConfigBackupOutcome: Equatable {
    case backedUp(folder: URL, files: [String])
    case nothingToBackUp
    case failed(String)
}

enum MultiplexerConfigBackup {
    static let folderName = "Config Backups"

    /// Copies every planned config into `<root>/Config Backups/<folder>`.
    /// Copies are staged in a hidden folder and moved into place only once
    /// all of them succeeded, so a failure leaves no partial backup.
    static func backUpForMacShortcuts(
        root: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> MultiplexerConfigBackupOutcome {
        let fileManager = FileManager.default
        guard let plan = MultiplexerConfigBackupPlanner.plan(
            home: home,
            environment: environment,
            now: now,
            fileExists: { fileManager.fileExists(atPath: $0) }
        ) else { return .nothingToBackUp }

        let backups = root.appendingPathComponent(folderName, isDirectory: true)
        let staging = backups.appendingPathComponent(".\(plan.folderName).partial-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in plan.files {
                let contents = try Data(contentsOf: URL(fileURLWithPath: file.source))
                try contents.write(to: staging.appendingPathComponent(file.name), options: .atomic)
            }
            var destination = backups.appendingPathComponent(plan.folderName, isDirectory: true)
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = backups.appendingPathComponent("\(plan.folderName)-\(suffix)", isDirectory: true)
                suffix += 1
            }
            try fileManager.moveItem(at: staging, to: destination)
            return .backedUp(folder: destination, files: plan.files.map(\.name))
        } catch {
            try? fileManager.removeItem(at: staging)
            return .failed(error.localizedDescription)
        }
    }
}
