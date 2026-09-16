//
//  HerdrSocketPath.swift
//  Vakta
//
//  Replicates herdr's own socket resolution for the one case Vakta actually
//  invokes: an explicit `--session <name>`. Confirmed by direct probe
//  against a real running herdr server (docs/herdr-events-plan.md):
//  `--session default` resolves to the root socket, not
//  `sessions/default/herdr.sock`, and an explicit `--session` wins over
//  `HERDR_SOCKET_PATH` entirely -- so `profile.environment` is irrelevant
//  here and deliberately not a parameter.

import Foundation

enum HerdrSocketPath {
    /// herdr's own special-cased session name for the default/root socket.
    private static let defaultSessionName = "default"

    static func resolve(sessionName: String, configDirectory: URL = defaultConfigDirectory()) -> URL {
        guard sessionName != defaultSessionName else {
            return configDirectory.appendingPathComponent("herdr.sock")
        }
        return configDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionName, isDirectory: true)
            .appendingPathComponent("herdr.sock")
    }

    /// `~/.config/herdr`. Not verified against `HERDR_CONFIG_PATH`
    /// overrides -- see docs/herdr-events-plan.md's "Base config directory"
    /// risk note.
    static func defaultConfigDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".config/herdr", isDirectory: true)
    }
}
