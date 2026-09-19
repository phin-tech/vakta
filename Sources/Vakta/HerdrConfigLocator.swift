//
//  HerdrConfigLocator.swift
//  Vakta
//
//  Pure helpers for the herdr config editor: where config.toml lives, and a
//  content fingerprint used to detect that someone else (herdr, a dotfile
//  tool, the user's editor) changed the file after we loaded it.

import CryptoKit
import Foundation

enum HerdrConfigLocator {
    /// `HERDR_CONFIG_PATH` if set and non-empty (a leading `~` expands against
    /// the supplied `home`), else `<home>/.config/herdr/config.toml`.
    static func resolve(environment: [String: String], home: URL) -> URL {
        if let override = environment["HERDR_CONFIG_PATH"], !override.isEmpty {
            if override == "~" { return home }
            if override.hasPrefix("~/") {
                return home.appendingPathComponent(String(override.dropFirst(2)))
            }
            return URL(fileURLWithPath: override)
        }
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("herdr", isDirectory: true)
            .appendingPathComponent("config.toml")
    }
}

enum HerdrConfigFingerprint {
    /// Fingerprint of a file that does not exist -- distinct from the
    /// fingerprint of an empty file.
    static let missing = "missing"

    static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
