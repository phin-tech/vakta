//
//  TmuxCommandStatusHookTests.swift
//  VaktaIntegrationTests
//
//  Real-shell regression for the tmux command-status hook. It uses a throwaway
//  tmux server and a temporary ZDOTDIR, then verifies that command exit codes
//  are stored per window rather than globally.
//

import XCTest
@testable import Vakta

final class TmuxCommandStatusHookTests: XCTestCase {
    func test_zshHookStoresLastExitCodePerTmuxWindow() throws {
        guard let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw XCTSkip("tmux not found on this machine")
        }
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw XCTSkip("zsh not found on this machine")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxCommandStatusHookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zshrc = root.appendingPathComponent(".zshrc")
        try (TmuxCommandStatusHook.zshSource + "\nPROMPT='%# '\n")
            .write(to: zshrc, atomically: true, encoding: .utf8)

        let socketName = "vakta-status-\(UUID().uuidString.prefix(8))"
        func tmux(_ args: [String]) throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["-L", socketName] + args
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        defer { _ = try? tmux(["kill-server"]) }

        _ = try tmux(["-f", "/dev/null", "new-session", "-d", "-s", "probe", "-n", "one", "ZDOTDIR=\(root.path) /bin/zsh -i"])
        _ = try tmux(["new-window", "-t", "probe", "-n", "two", "ZDOTDIR=\(root.path) /bin/zsh -i"])
        _ = try tmux(["send-keys", "-t", "probe:one", "false", "Enter"])
        _ = try tmux(["send-keys", "-t", "probe:two", "sh -c 'exit 7'", "Enter"])

        XCTAssertEqual(try waitForOption("one", tmux: tmux), "1")
        XCTAssertEqual(try waitForOption("two", tmux: tmux), "7")
    }

    private func waitForOption(
        _ window: String,
        tmux: ([String]) throws -> String
    ) throws -> String {
        for _ in 0..<40 {
            let value = try tmux(["show-options", "-w", "-t", "probe:\(window)", "-v", "@vakta_last_exit"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return ""
    }
}
