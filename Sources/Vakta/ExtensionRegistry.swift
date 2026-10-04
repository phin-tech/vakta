//
//  ExtensionRegistry.swift
//  Vakta
//
//  The persisted list of Linked Extensions (`extensions.json`): which
//  directories are linked, whether each is enabled or in developer mode, and
//  what the user approved. Vakta stores nothing else about an Extension.

import Foundation

struct LinkedExtensionRecord: Codable, Equatable {
    /// Standardized absolute path; the record's identity.
    var directory: String
    var enabled: Bool
    var developerMode: Bool
    var approved: TrustFingerprint?
    /// Whether the Extension's `notify` messages may show (default on).
    var notifications: Bool
    /// Shipped with Vakta: linked automatically, trusted by the app's own
    /// signature, never unlinked.
    var builtIn: Bool

    init(
        directory: String, enabled: Bool, developerMode: Bool, approved: TrustFingerprint?,
        notifications: Bool = true, builtIn: Bool = false
    ) {
        self.directory = directory
        self.enabled = enabled
        self.developerMode = developerMode
        self.approved = approved
        self.notifications = notifications
        self.builtIn = builtIn
    }

    private enum CodingKeys: String, CodingKey {
        case directory, enabled, developerMode, approved, notifications, builtIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            directory: try container.decode(String.self, forKey: .directory),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            developerMode: try container.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false,
            approved: try container.decodeIfPresent(TrustFingerprint.self, forKey: .approved),
            notifications: try container.decodeIfPresent(Bool.self, forKey: .notifications) ?? true,
            builtIn: try container.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        )
    }
}

struct ExtensionRegistry: Equatable {
    var records: [LinkedExtensionRecord]
}

/// Versioned envelope; an unknown future version is not decodable, so the
/// file is preserved rather than overwritten.
struct ExtensionRegistryFileCodec: FilePayloadCodec {
    static let currentVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var records: [LinkedExtensionRecord]
    }

    func decode(_ data: Data) -> ExtensionRegistry? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion
        else { return nil }
        return ExtensionRegistry(records: envelope.records)
    }

    func encode(_ payload: ExtensionRegistry) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(Envelope(version: Self.currentVersion, records: payload.records))
    }
}

/// Where Built-in Extensions live, and reconciling them with the registry.
enum BuiltInExtensions {
    /// `Vakta.app/Contents/Extensions` for the app; under `swift run`, the
    /// repository's `extensions/` (found by walking up from the executable
    /// to the directory holding `Package.swift`).
    static func roots(bundleURL: URL, executableURL: URL, fileExists: (String) -> Bool) -> [URL] {
        if bundleURL.pathExtension == "app" {
            return [bundleURL.appendingPathComponent("Contents/Extensions", isDirectory: true)]
        }
        var directory = executableURL.deletingLastPathComponent()
        while directory.path != "/" {
            if fileExists(directory.appendingPathComponent("Package.swift").path) {
                return [directory.appendingPathComponent("extensions", isDirectory: true)]
            }
            directory = directory.deletingLastPathComponent()
        }
        return []
    }

    /// Records after reconciling with the built-in directories found now:
    /// new ones are added (enabled), ones no longer shipped are dropped, and
    /// existing ones keep their switches. Linked records are untouched.
    static func reconcile(_ records: [LinkedExtensionRecord], builtInDirectories: [String]) -> [LinkedExtensionRecord] {
        let shipped = Set(builtInDirectories)
        var kept = records.filter { !$0.builtIn || shipped.contains($0.directory) }
        for directory in builtInDirectories where !kept.contains(where: { $0.directory == directory }) {
            kept.append(LinkedExtensionRecord(directory: directory, enabled: true, developerMode: false, approved: nil, builtIn: true))
        }
        return kept
    }
}
