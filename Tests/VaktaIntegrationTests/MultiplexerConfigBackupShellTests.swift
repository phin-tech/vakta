//
//  MultiplexerConfigBackupShellTests.swift
//  VaktaIntegrationTests
//
//  Copying tmux/herdr configs into Vakta's backup folder against a temporary
//  home and storage root -- never the user's real files.

import XCTest
@testable import Vakta

final class MultiplexerConfigBackupShellTests: XCTestCase {
    private var sandbox: URL!
    private var home: URL!
    private var root: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiplexerConfigBackupShellTests-\(UUID().uuidString)", isDirectory: true)
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        root = sandbox.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ text: String, to relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func test_copiesExistingConfigs_followingSymlinks_andLeavesOriginalsAlone() throws {
        let dotfile = try write("set -g prefix C-a\n", to: "dotfiles/tmux.conf")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".tmux.conf"), withDestinationURL: dotfile)
        let herdr = try write("[keys]\nprefix = \"ctrl+b\"\n", to: ".config/herdr/config.toml")

        let outcome = MultiplexerConfigBackup.backUpForMacShortcuts(root: root, home: home, environment: [:], now: Date())

        guard case .backedUp(let folder, let names) = outcome else { return XCTFail("expected a backup, got \(outcome)") }
        XCTAssertEqual(names, ["dot-tmux.conf", "herdr-config.toml"])
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "Config Backups")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("dot-tmux.conf"), encoding: .utf8), "set -g prefix C-a\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("herdr-config.toml"), encoding: .utf8), "[keys]\nprefix = \"ctrl+b\"\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("dot-tmux.conf").path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular, "a copy of the contents, not a symlink")
        XCTAssertEqual(try String(contentsOf: herdr, encoding: .utf8), "[keys]\nprefix = \"ctrl+b\"\n", "original untouched")
    }

    func test_noConfigs_writesNothing() {
        let outcome = MultiplexerConfigBackup.backUpForMacShortcuts(root: root, home: home, environment: [:], now: Date())

        XCTAssertEqual(outcome, .nothingToBackUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Config Backups").path))
    }

    func test_unreadableConfig_failsWithoutAPartialFolder() throws {
        let herdr = try write("x", to: ".config/herdr/config.toml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: herdr.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: herdr.path) }

        let outcome = MultiplexerConfigBackup.backUpForMacShortcuts(root: root, home: home, environment: [:], now: Date())

        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        let backups = root.appendingPathComponent("Config Backups")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        XCTAssertEqual(leftovers, [], "no half-written backup folder")
    }
}
