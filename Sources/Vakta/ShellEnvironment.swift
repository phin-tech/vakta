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
    /// Synchronous and blocking -- callers on the main actor should use
    /// `ResolvedPATH` instead, which does the actual process work off it.
    static func resolvedPATH(timeout: TimeInterval = 4) -> String {
        loginShellPATH(timeout: timeout) ?? fallbackPATH()
    }

    /// Pure: the value of a `PATH=...` line, if one is present. Extracted
    /// from `loginShellPATH` so this parsing is directly testable without
    /// executing a shell.
    static func extractPATH(from envOutput: String) -> String? {
        for line in envOutput.split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix("PATH=") {
            let value = String(line.dropFirst("PATH=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Used when the login shell can't be queried: the system PATH plus the
    /// common user/tool bin dirs a multiplexer is likely installed in. The
    /// explicit fallback `ResolvedPATH`/`resolvedPATH` fall back to.
    static func fallbackPATH(home: String = NSHomeDirectory()) -> String {
        [
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

    private static func loginShellPATH(timeout: TimeInterval) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        // Login + interactive so profile *and* rc files (where PATH edits
        // often live) run. `env` prints the real environment; no tty, so
        // `-c` returns. Inherits Vakta's own environment (unlike
        // `ProcessRunner`, which always sets an explicit PATH/HOME) since
        // the whole point here is asking the shell to recompute PATH from
        // whatever the user's actual login environment produces.
        let result = BoundedProcessRunner.run(
            executable: shell,
            arguments: ["-lic", "env"],
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout
        )
        guard case .success(let output) = result else { return nil }
        return extractPATH(from: output)
    }
}

/// Resolves the login-shell PATH on a background thread, kicked off as soon
/// as this is created -- off the main actor entirely, unlike
/// `ShellEnvironment.resolvedPATH()` called directly, which blocks whatever
/// thread calls it for the shell's full run time. `value(waitingUpTo:)`
/// still blocks its caller, but `SessionStore` only ever calls it from a
/// background queue, never the main actor -- see its `init`/`finishLaunch`.
///
/// `@unchecked Sendable`: the only mutable state is `resolvedValue`, guarded
/// by `lock` on every access; `semaphore` is thread-safe by design. No other
/// stored property is ever mutated after `init`.
final class ResolvedPATH: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var resolvedValue: String?

    init(timeout: TimeInterval = 4) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let path = ShellEnvironment.resolvedPATH(timeout: timeout)
            guard let self else { return }
            self.lock.lock()
            self.resolvedValue = path
            self.lock.unlock()
            self.semaphore.signal()
        }
    }

    /// Blocks the calling thread up to `timeout` for the background
    /// resolution to land; returns `ShellEnvironment.fallbackPATH()` if it
    /// hasn't by then (the resolution keeps running regardless -- a late
    /// result is simply never read).
    func value(waitingUpTo timeout: TimeInterval) -> String {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return ShellEnvironment.fallbackPATH()
        }
        lock.lock()
        defer { lock.unlock() }
        return resolvedValue ?? ShellEnvironment.fallbackPATH()
    }
}
