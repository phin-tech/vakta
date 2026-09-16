//
//  LaunchTarget.swift
//  Vakta
//
//  What server a profile's discovery/status queries and attach identity
//  actually point at, resolved from the profile alone (pure -- no process
//  execution). `SessionDiscovery` and `HerdrAgentStatus` consume a resolved
//  `MultiplexerTarget` instead of re-deriving "herdr"/"tmux" from scratch
//  and running the bare binary name with no environment.
//
//  Previously: `SessionDiscovery`/`HerdrAgentStatus` invoked bare `herdr`/
//  `tmux` with only PATH+HOME, discarding `profile.command`'s actual path,
//  `profile.environment` (e.g. `HERDR_SOCKET_PATH`, which selects which
//  local herdr server a command talks to), and any server-selecting flags
//  in `profile.arguments`. A remote herdr profile (`--remote host --session
//  {name}`) would silently query the LOCAL herdr server instead -- `herdr
//  session list` has no per-invocation remote flag at all, so there is no
//  reliable local query for "what's actually on that remote server."

import Foundation

enum LaunchTarget: Equatable {
    case multiplexer(MultiplexerTarget)
    /// The profile's command isn't a known multiplexer, or its arguments
    /// make the actual server ambiguous/unreachable from a locally-run
    /// query. Distinct from "queried, found nothing" -- see
    /// `SessionStore.DiscoveryResult`.
    case unsupported
}

struct MultiplexerTarget: Equatable {
    enum Backend: Equatable {
        case herdr
        case tmux
    }

    var backend: Backend
    /// `profile.command` verbatim -- an absolute/custom-named binary is
    /// honored rather than a hardcoded `"herdr"`/`"tmux"` literal.
    var executable: String
    /// A custom tmux socket *path* (`-S <path>` in the profile's arguments),
    /// if any. `nil` uses tmux's default socket. Mutually exclusive with
    /// `tmuxSocketName` in practice (tmux itself rejects both together);
    /// `LaunchTargetResolver` prefers whichever flag it finds first.
    var tmuxSocketPath: String?
    /// A custom tmux socket *name* (`-L <name>`, under tmux's default socket
    /// directory), if any -- tmux's other, more common way to address a
    /// distinct server instance.
    var tmuxSocketName: String?
    /// `profile.environment` verbatim, applied on top of PATH/HOME for
    /// every discovery/status query against this target -- e.g. a profile
    /// that sets `HERDR_SOCKET_PATH` to address a specific local herdr
    /// server instance.
    var environment: [String: String]

    /// The argv to list this target's existing sessions.
    var discoveryArgv: [String] {
        switch backend {
        case .herdr:
            return [executable, "session", "list"]
        case .tmux:
            var argv = [executable]
            if let tmuxSocketPath {
                argv += ["-S", tmuxSocketPath]
            } else if let tmuxSocketName {
                argv += ["-L", tmuxSocketName]
            }
            argv += ["list-sessions", "-F", "#{session_name}"]
            return argv
        }
    }

    /// The argv to query agent status for `sessionName`, or `nil` for a
    /// backend with no equivalent (only herdr has agents).
    func statusArgv(sessionName: String) -> [String]? {
        guard backend == .herdr else { return nil }
        return [executable, "--session", sessionName, "agent", "list"]
    }
}

/// The outcome of querying (or not attempting to query) a profile's server
/// for existing sessions. See `SessionStore.discovered`, which is keyed by
/// this type.
enum DiscoveryResult: Equatable {
    case unsupported
    case sessions([String])
}

enum LaunchTargetResolver {
    static func resolve(_ profile: Profile) -> LaunchTarget {
        guard let backend = backend(of: profile.command) else { return .unsupported }
        if backend == .herdr, referencesRemoteFlag(profile.arguments) { return .unsupported }
        return .multiplexer(MultiplexerTarget(
            backend: backend,
            executable: profile.command,
            tmuxSocketPath: backend == .tmux ? tmuxToken("-S", in: profile.arguments) : nil,
            tmuxSocketName: backend == .tmux ? tmuxToken("-L", in: profile.arguments) : nil,
            environment: profile.environment
        ))
    }

    /// Whether `profile`'s command is a multiplexer Vakta knows about at
    /// all, independent of whether its specific target is queryable. Lets a
    /// caller distinguish "not a multiplexer, nothing to show" (a plain
    /// shell profile) from "a multiplexer, but this one's target can't be
    /// reliably queried" (`resolve` returning `.unsupported` for a herdr
    /// `--remote` profile) -- see `SessionStore.DiscoveryResult`.
    static func isKnownMultiplexerCommand(_ profile: Profile) -> Bool {
        backend(of: profile.command) != nil
    }

    private static func backend(of command: String) -> MultiplexerTarget.Backend? {
        switch (command as NSString).lastPathComponent {
        case "herdr": return .herdr
        case "tmux": return .tmux
        default: return nil
        }
    }

    /// herdr's `--remote <ssh-target>` attaches through SSH to a different
    /// server entirely; `herdr session list` has no per-invocation remote
    /// flag, so there is no way to query that server's session list from
    /// here.
    private static func referencesRemoteFlag(_ arguments: String) -> Bool {
        arguments.split(separator: " ").contains("--remote")
    }

    /// A `<flag> <value>` token pair (`-S <path>` or `-L <name>`, tmux's two
    /// custom-socket flags). Simple whitespace splitting, matching the
    /// space-separated flag convention every documented/built-in profile
    /// already uses -- a quoted value in the template isn't recognized.
    private static func tmuxToken(_ flag: String, in arguments: String) -> String? {
        let tokens = arguments.split(separator: " ").map(String.init)
        guard let index = tokens.firstIndex(of: flag), tokens.indices.contains(index + 1) else { return nil }
        return tokens[index + 1]
    }
}
