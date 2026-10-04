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

    init(directory: String, enabled: Bool, developerMode: Bool, approved: TrustFingerprint?, notifications: Bool = true) {
        self.directory = directory
        self.enabled = enabled
        self.developerMode = developerMode
        self.approved = approved
        self.notifications = notifications
    }

    private enum CodingKeys: String, CodingKey {
        case directory, enabled, developerMode, approved, notifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            directory: try container.decode(String.self, forKey: .directory),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            developerMode: try container.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false,
            approved: try container.decodeIfPresent(TrustFingerprint.self, forKey: .approved),
            notifications: try container.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
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
