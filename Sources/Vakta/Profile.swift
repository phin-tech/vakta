//
//  Profile.swift
//  Vakta
//
//  A session profile: the recipe for what a new session spawns. Every
//  `Session` is created from one (see `SessionStore.createSession`), so the
//  base command, working directory, and environment all live here rather than
//  being hardcoded at the surface-creation site.
//
//  `Codable` and persisted to disk (see `ProfilePersistence`); the built-ins
//  below seed the file on first launch.

import Foundation
import GhosttyTerminal

struct Profile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()

    /// Shown in the sidebar row (until the shell reports an OSC title) and in
    /// the "New Session" menu.
    var name: String

    /// The base command spawned in the session's pty (exec backend). A bare,
    /// `$PATH`-resolvable name works — libghostty threads it through a login
    /// shell's `exec -l <command> <arguments>`, so the whole line is
    /// shell-parsed (arguments below are honored, and safe session names work).
    var command: String

    /// Arguments appended after `command`, as one shell-style string. The token
    /// `{name}` is replaced with the session's multiplexer name (see
    /// `resolvedCommand(sessionName:)`), which is what makes a session
    /// attach-or-create and therefore survive a restart. Examples:
    ///   - herdr, local named:  `--session {name}`
    ///   - herdr, remote:       `--remote me@host --session {name}`
    ///   - tmux, attach/create: `new-session -A -s {name}`
    /// Empty for a plain shell (no named session to reconnect to).
    var arguments: String

    /// Working directory for the spawned command; `nil` inherits Vakta's.
    var workingDirectory: String?

    /// Environment variables to **set** on the spawned child. Additive only —
    /// passed through `ghostty_surface_config_s.env_vars`, which the wrapper
    /// documents as adding to (never removing from) the inherited environment.
    var environment: [String: String]

    /// Environment variables to **remove** from the spawned child. Implemented
    /// by prefixing the command with `env -u KEY …` (see
    /// `resolvedCommand(sessionName:)`), so the child execs with them gone.
    ///
    /// This deliberately does NOT `unsetenv()` on Vakta's own process:
    /// mutating `environ` corrupts the array libghostty walks while building
    /// the child environment (it scans each `KEY=VALUE` entry for `=`), which
    /// segfaults inside `ghostty_surface_new`. Scrubbing in the child via `env`
    /// avoids touching `environ` at all, and is per-session rather than global.
    var scrubbedEnvironmentKeys: [String]

    /// Whether the surface stays open after `command` exits. `nil` leaves
    /// libghostty's default (close on exit); `true` shows the "press any key
    /// to close" screen instead.
    var waitAfterCommand: Bool?

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        arguments: String = "",
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        scrubbedEnvironmentKeys: [String] = [],
        waitAfterCommand: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.scrubbedEnvironmentKeys = scrubbedEnvironmentKeys
        self.waitAfterCommand = waitAfterCommand
    }

    /// Whether this profile targets a named, reconnectable session -- i.e. its
    /// arguments reference `{name}`. Such sessions attach-or-create on restore;
    /// others (a plain shell) just start fresh.
    var attachesToNamedSession: Bool {
        arguments.contains("{name}")
    }

    /// The full command line for a session: an optional `env -u …` scrub
    /// prefix, then the command, then arguments with `{name}` substituted.
    /// libghostty shell-wraps this as `exec -l <line>`, so the `env` prefix
    /// unsets the keys for the child only.
    func resolvedCommand(sessionName: String) -> String {
        var parts: [String] = []
        if !scrubbedEnvironmentKeys.isEmpty {
            parts.append("/usr/bin/env")
            for key in scrubbedEnvironmentKeys {
                parts.append("-u")
                parts.append(key)
            }
        }
        parts.append(command)
        let args = arguments
            .replacingOccurrences(of: "{name}", with: sessionName)
            .trimmingCharacters(in: .whitespaces)
        if !args.isEmpty {
            parts.append(args)
        }
        return parts.joined(separator: " ")
    }

    /// The surface options libghostty consumes for a session of this profile.
    func makeSurfaceOptions(sessionName: String) -> TerminalSurfaceOptions {
        TerminalSurfaceOptions(
            workingDirectory: workingDirectory,
            envVars: environment,
            command: resolvedCommand(sessionName: sessionName),
            waitAfterCommand: waitAfterCommand
        )
    }
}

extension Profile {
    /// The default profile: a herdr multiplexer session.
    ///
    /// It scrubs the `HERDR_*` variables so a session never detects itself as
    /// nested. herdr refuses a nested launch by default ("nested herdr is
    /// disabled by default … recursive descent denied"), which happens
    /// whenever Vakta is itself launched from inside a herdr session — from a
    /// herdr shell, from a terminal that is a herdr pane, etc. Scrubbing these
    /// makes each Vakta session a fresh top-level herdr regardless of how
    /// Vakta was started.
    static let herdr = Profile(
        name: "herdr",
        command: "herdr",
        // `--session {name}` makes each Vakta session a distinct, persistent
        // herdr session that reconnects on the next launch.
        arguments: "--session {name}",
        scrubbedEnvironmentKeys: [
            "HERDR_ENV",
            "HERDR_SOCKET_PATH",
            "HERDR_WORKSPACE_ID",
            "HERDR_TAB_ID",
            "HERDR_PANE_ID",
        ]
    )

    /// A tmux multiplexer session. Same nesting story as herdr: tmux marks a
    /// pane with `TMUX` / `TMUX_PANE` and refuses to start nested ("sessions
    /// should be nested with care, unset $TMUX to force") when they're
    /// inherited, so this profile scrubs them for the same reason `.herdr`
    /// scrubs `HERDR_*` (see `scrubbedEnvironmentKeys`).
    static let tmux = Profile(
        name: "tmux",
        command: "tmux",
        // `new-session -A -s {name}` attaches if the session exists, else
        // creates it -- so the session survives a Vakta restart.
        arguments: "new-session -A -s {name}",
        scrubbedEnvironmentKeys: [
            "TMUX",
            "TMUX_PANE",
        ]
    )

    /// A plain login-shell profile — a scratch terminal, and a convenient
    /// smoke test on machines without herdr installed.
    static let shell = Profile(
        name: "shell",
        command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    )
}
