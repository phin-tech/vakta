//
//  ExtensionManifest.swift
//  Vakta
//
//  Pure model of a Linked Extension's `vakta-extension.json` (see
//  docs/extensions-plan.md): decoding, validation, and where its executable
//  lives. The executable must be a relative path inside the Extension's own
//  directory, because Trust pins its bytes.

import Foundation

struct ExtensionManifest: Equatable {
    static let fileName = "vakta-extension.json"

    struct PanelViewDeclaration: Codable, Equatable {
        var id: String
        var title: String
        var symbol: String
    }

    var id: String
    var name: String
    var description: String?
    /// argv; `command[0]` is relative to the Extension directory.
    var command: [String]
    /// argv commands run once, in order, after Trust is granted.
    var build: [[String]]
    var panelViews: [PanelViewDeclaration]
    /// Environment variables the Extension receives from the user's login
    /// shell: exact names or `PREFIX_*`. Everything else is withheld.
    var environment: [String] = []

    /// Decodes manifest bytes; `nil` when they aren't a manifest at all.
    static func decode(_ data: Data) -> ExtensionManifest? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return ExtensionManifest(
            id: file.id, name: file.name, description: file.description, command: file.command,
            build: file.build ?? [], panelViews: file.panelViews ?? [], environment: file.environment ?? []
        )
    }

    /// Everything wrong with a decoded manifest, as user-presentable lines.
    var problems: [String] {
        var found: [String] = []
        if id.isEmpty {
            found.append("ID is required.")
        } else if !id.unicodeScalars.allSatisfy(Self.idCharacters.contains) {
            found.append("ID may contain only lowercase letters, digits, dots and dashes.")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("Name is required.")
        }
        if command.isEmpty {
            found.append("Command is required.")
        } else if executableURL(in: URL(fileURLWithPath: "/extension", isDirectory: true)) == nil {
            found.append("Command must start with a path inside the extension directory, like ./run.")
        }
        if build.contains(where: \.isEmpty) {
            found.append("Build commands can't be empty.")
        }
        var seen = Set<String>()
        for view in panelViews {
            if !seen.insert(view.id).inserted {
                found.append("Panel view IDs must be unique (\(view.id)).")
            }
            if view.title.isEmpty || view.symbol.isEmpty {
                found.append("Panel view \(view.id) needs a title and a symbol.")
            }
        }
        return found + ExtensionEnvironment.problems(environment)
    }

    /// `command[0]` resolved inside `directory`, or `nil` when it is absolute,
    /// a bare program name (a PATH lookup Trust couldn't pin), or escapes the
    /// directory.
    func executableURL(in directory: URL) -> URL? {
        guard let first = command.first, !first.hasPrefix("/"), first.contains("/") else { return nil }
        let base = directory.standardizedFileURL
        let resolved = URL(fileURLWithPath: first, relativeTo: base).standardizedFileURL
        guard resolved.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else { return nil }
        return resolved
    }

    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    private struct File: Decodable {
        var id: String
        var name: String
        var description: String?
        var command: [String]
        var build: [[String]]?
        var panelViews: [PanelViewDeclaration]?
        var environment: [String]?
    }
}
