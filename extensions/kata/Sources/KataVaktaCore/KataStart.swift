//
//  KataStart.swift
//  KataVaktaCore
//
//  Starting work on an issue: the agent command (configurable, with
//  {id}/{title}/{prompt} placeholders substituted inside argv words), the
//  Effects that open it in a pane, and the map of which Session started
//  which issue (kept in the Extension's own config directory).

import Foundation
import VaktaExtensionKit

public struct KataConfig: Codable, Equatable {
    /// argv for the agent; each word may contain {id}, {title}, {prompt}.
    public var agentCommand: [String]

    public static let `default` = KataConfig(agentCommand: ["claude", "{prompt}"])

    public init(agentCommand: [String]) {
        self.agentCommand = agentCommand
    }

    /// Missing, unreadable or empty config means the default.
    public static func decode(_ data: Data?) -> KataConfig {
        guard let data, let config = try? JSONDecoder().decode(KataConfig.self, from: data), !config.agentCommand.isEmpty else {
            return .default
        }
        return config
    }
}

public enum KataStart {
    public static let callback = "start"

    public static func prompt(id: String, title: String) -> String {
        "Work on Kata issue \(id): \(title). Read it first with `kata show \(id)`."
    }

    /// Placeholders are replaced inside each argv word; a value never
    /// becomes extra words.
    public static func command(template: [String], id: String, title: String) -> [String] {
        let prompt = prompt(id: id, title: title)
        return template.map {
            $0.replacingOccurrences(of: "{prompt}", with: prompt)
                .replacingOccurrences(of: "{id}", with: id)
                .replacingOccurrences(of: "{title}", with: title)
        }
    }

    public static func effects(id: String, workspace: String, command: [String]) -> [Effect] {
        [.openPane(cwd: workspace, command: command, title: id), .toast(text: "Started \(id)"), .refresh]
    }

    static func button(id: String, title: String) -> ViewButton {
        ViewButton(
            title: "Start", symbol: "play.fill", callback: callback,
            payload: .object(["id": .string(id), "title": .string(title)]),
            style: .primary, confirm: nil, shortcut: "cmd+shift+return"
        )
    }
}

/// Which issue each Session started, keyed by "backend:sessionName".
public struct KataSessionMap: Codable, Equatable {
    public private(set) var issues: [String: String] = [:]

    public init() {}

    public static func key(_ sessionKey: SessionKey) -> String {
        "\(sessionKey.backend):\(sessionKey.sessionName)"
    }

    public mutating func record(_ issue: String, for sessionKey: SessionKey) {
        issues[Self.key(sessionKey)] = issue
    }

    public func issue(for sessionKey: SessionKey) -> String? {
        issues[Self.key(sessionKey)]
    }

    public static func decode(_ data: Data?) -> KataSessionMap {
        guard let data, let map = try? JSONDecoder().decode(KataSessionMap.self, from: data) else { return KataSessionMap() }
        return map
    }
}
