//
//  HerdrConfigFile.swift
//  Vakta
//
//  The disk boundary for herdr's config.toml: read with a content
//  fingerprint, and write atomically after taking a timestamped backup of
//  whatever is there. The path is resolved through symlinks first -- dotfile
//  setups commonly symlink config.toml, and an atomic replace of the link
//  itself would silently detach it from the dotfiles repo.

import Foundation

enum HerdrConfigLoadOutcome: Equatable {
    case missing
    case loaded(String, String) // text, fingerprint
    case unreadable(String)
}

struct HerdrConfigFile {
    let url: URL
    let backupsToKeep: Int
    let now: () -> Date

    private var backupInfix: String { ".bak-vakta-" }

    func load() -> HerdrConfigLoadOutcome {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return .missing }
        do {
            let data = try Data(contentsOf: target)
            guard let text = String(data: data, encoding: .utf8) else {
                return .unreadable("config.toml is not valid UTF-8")
            }
            return .loaded(text, HerdrConfigFingerprint.of(text))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Backs up the existing file (if any), then atomically writes `text`.
    /// A backup failure aborts the save: never overwrite without a copy.
    func save(_ text: String) -> FileSaveOutcome {
        let target = url.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: target, to: backupURL(beside: target))
            }
            try text.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            return .failure(error)
        }
        pruneBackups(beside: target)
        return .success
    }

    private func backupURL(beside target: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = target.lastPathComponent + backupInfix + formatter.string(from: now())
        var candidate = target.deletingLastPathComponent().appendingPathComponent(base)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = target.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private func pruneBackups(beside target: URL) {
        let prefix = target.lastPathComponent + backupInfix
        let directory = target.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let backups = names.filter { $0.hasPrefix(prefix) }.sorted()
        for name in backups.dropLast(max(backupsToKeep, 0)) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
