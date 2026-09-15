//
//  ShellEnvironment.swift
//  Vakta
//
//  Resolves the user's real login-shell PATH.
//
//  A GUI app launched by LaunchServices (double-clicked / `open`) inherits a
//  minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), NOT the PATH the user's
//  shell builds from their profile. So a bare command like `herdr` (typically
//  in `~/.local/bin`) isn't found -- the child dies with
//  "env: herdr: No such file or directory". We fix that by asking the user's
//  login shell for its PATH once and handing it to every spawned session.

import Foundation

enum ShellEnvironment {
    /// The user's login-shell PATH, or a sensible fallback if it can't be
    /// resolved. Shell-agnostic: it runs the login shell and reads `env`, so
    /// the `PATH=` line is colon-separated regardless of shell (fish included).
    static func resolvedPATH(timeout: TimeInterval = 4) -> String {
        loginShellPATH(timeout: timeout) ?? fallbackPATH()
    }

    private static func loginShellPATH(timeout: TimeInterval) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Login + interactive so profile *and* rc files (where PATH edits often
        // live) run. `env` prints the real environment; no tty, so -c returns.
        process.arguments = ["-lic", "env"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix("PATH=") {
            let value = String(line.dropFirst("PATH=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Used when the login shell can't be queried: the system PATH plus the
    /// common user/tool bin dirs a multiplexer is likely installed in.
    private static func fallbackPATH() -> String {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.cargo/bin",
        ].joined(separator: ":")
    }
}
