//
//  KataStorage.swift
//  kata-vakta
//
//  Files in the Extension's own config directory (VAKTA_EXTENSION_CONFIG_DIR,
//  which Vakta creates): `config.json` (agent command) and `sessions.json`
//  (which Session started which issue). Vakta never reads these.

import Foundation
import KataVaktaCore

enum KataStorage {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["VAKTA_EXTENSION_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func config() -> KataConfig {
        KataConfig.decode(directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("config.json")) })
    }

    static func sessions() -> KataSessionMap {
        KataSessionMap.decode(directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("sessions.json")) })
    }

    static func save(_ map: KataSessionMap) {
        guard let url = directory?.appendingPathComponent("sessions.json"), let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
