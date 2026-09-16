//
//  PersistedFileStore.swift
//  Vakta
//
//  Shared JSON file-storage boundary for settings/profile/workspace
//  persistence. Each existing `*Persistence` enum repeats Application Support
//  resolution, directory creation, `try?` decoding, and silent-`nil`-on-error
//  writes; this type gives them one contract with explicit load/save outcomes
//  and an injected root directory so corrupt/unreadable files are never
//  silently overwritten and tests never touch real user settings.

import Foundation

/// The result of reading a persisted file. Distinguishes "never written"
/// from "written but can't be understood" -- callers must not treat a
/// corrupt/unreadable file the same as a first launch.
enum FileLoadOutcome<Payload> {
    /// No file exists at the path yet -- first launch, safe to seed.
    case missing
    /// Decoded successfully (through any migration the codec applies).
    case loaded(Payload)
    /// A file exists and could be read, but the codec could not decode it
    /// (malformed JSON, or a shape no known version/migration recognizes).
    /// Carries the original bytes so callers can preserve them.
    case corrupt(bytes: Data)
    /// The file exists but could not be read (permissions, I/O error).
    case unreadable(Error)
}

/// The result of writing a persisted file.
enum FileSaveOutcome {
    case success
    case failure(Error)
}

/// Resolves (and creates) `~/Library/Application Support/Vakta`, the shared
/// root every persisted settings/profile/workspace file lives under. A single
/// implementation, rather than each `*Persistence` type repeating the same
/// `FileManager` calls independently.
///
/// Throws rather than falling back to the temp directory on failure: silently
/// writing "persisted" settings somewhere the OS can wipe at any time is
/// worse than failing loudly, since every store built on top of this treats
/// its root as durable. The one call site (`AppDelegate.applicationDidFinishLaunching`)
/// treats resolution failure the same as the existing no-display-session
/// check: a fatal alert and a clean exit before any store is constructed.
enum ApplicationSupportRoot {
    static func resolve(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Vakta", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum PersistedFileStoreError: Error {
    /// `FilePayloadCodec.encode` returned `nil` for a well-formed in-memory
    /// value -- an implementation bug in the codec, not an I/O failure.
    case encodingFailed
}

extension Notification.Name {
    /// Posted synchronously, on the calling thread, whenever
    /// `PersistedFileStore.save` fails. Every `*Persistence.save` call site
    /// declares its `FileSaveOutcome` `@discardableResult` (most callers
    /// legitimately have no synchronous recovery to do), so without this a
    /// write failure was otherwise completely invisible -- this is the one
    /// choke point every save goes through, so it's the one place that can
    /// guarantee a failure is observable somewhere. `PersistenceFailureCenter`
    /// is the (optional) MainActor-observable subscriber.
    static let vaktaPersistedFileSaveFailed = Notification.Name("vaktaPersistedFileSaveFailed")
}

enum PersistedFileSaveFailureUserInfoKey {
    static let fileName = "fileName"
    static let message = "message"
}

/// Pure: turns a save failure into a short, user-presentable message. No I/O.
enum PersistenceFailureMessage {
    static func describe(fileName: String, error: Error) -> String {
        if error is PersistedFileStoreError {
            return "Couldn't save \(fileName): the data to save was invalid."
        }
        return "Couldn't save \(fileName): \((error as NSError).localizedDescription)"
    }
}

/// Pure decode/encode + migration for one payload type. Implementations must
/// not perform I/O; `PersistedFileStore` supplies the bytes.
protocol FilePayloadCodec {
    associatedtype Payload
    /// Decodes `data` into a `Payload`, applying any version migration.
    /// Returns `nil` when `data` is not a recognized shape at all.
    func decode(_ data: Data) -> Payload?
    /// Encodes `payload` for writing. Returns `nil` only if encoding itself
    /// is impossible (should not happen for well-formed in-memory values).
    func encode(_ payload: Payload) -> Data?
}

/// A JSON file at an injected root, read/written through a `FilePayloadCodec`.
/// The root is supplied by the caller (production resolves Application
/// Support once at the app boundary; tests inject a temporary directory) --
/// this type never falls back to a different location on its own.
struct PersistedFileStore<Codec: FilePayloadCodec> {
    let root: URL
    let fileName: String
    let codec: Codec
    let fileManager: FileManager = .default

    var fileURL: URL { root.appendingPathComponent(fileName) }

    /// Reads and decodes the file. Never writes as a side effect.
    func load() -> FileLoadOutcome<Codec.Payload> {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .unreadable(error)
        }

        guard let payload = codec.decode(data) else { return .corrupt(bytes: data) }
        return .loaded(payload)
    }

    /// Atomically writes `payload`. Never creates the injected root itself
    /// and never falls back to a different location on failure. A failure
    /// posts `.vaktaPersistedFileSaveFailed` before returning (see that
    /// notification's doc comment) so it is never entirely silent even when
    /// the caller discards the result.
    func save(_ payload: Codec.Payload) -> FileSaveOutcome {
        guard let data = codec.encode(payload) else {
            return fail(PersistedFileStoreError.encodingFailed)
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return .success
        } catch {
            return fail(error)
        }
    }

    private func fail(_ error: Error) -> FileSaveOutcome {
        NotificationCenter.default.post(
            name: .vaktaPersistedFileSaveFailed,
            object: nil,
            userInfo: [
                PersistedFileSaveFailureUserInfoKey.fileName: fileName,
                PersistedFileSaveFailureUserInfoKey.message: PersistenceFailureMessage.describe(
                    fileName: fileName,
                    error: error
                )
            ]
        )
        return .failure(error)
    }
}

/// A trivial `FilePayloadCodec` for a payload with no legacy shape to
/// migrate from -- just `Codable` in, `Codable` out.
struct JSONCodec<Payload: Codable>: FilePayloadCodec {
    func decode(_ data: Data) -> Payload? {
        try? JSONDecoder().decode(Payload.self, from: data)
    }

    func encode(_ payload: Payload) -> Data? {
        try? JSONEncoder().encode(payload)
    }
}

/// The on-disk shape `KeybindingPersistence` writes: a schema version
/// alongside the bindings. A file written before versioning is a bare
/// `[Keybinding]` array and is treated as version 1.
struct StoredKeybindingsPayload: Codable, Equatable {
    var version: Int
    var bindings: [Keybinding]
}

/// Decodes/migrates the keybindings file for `PersistedFileStore`, replacing
/// the inline `try?` decode-then-fallback pair in
/// `KeybindingPersistence.load`. Recognizes the current versioned envelope
/// and the legacy bare-array shape; any other shape (malformed JSON, or an
/// envelope whose `version` is newer than `currentVersion`) is not decodable
/// -- the caller must preserve rather than reinterpret it.
struct KeybindingFileCodec: FilePayloadCodec {
    /// Bump when adding a migration in `KeybindingStartupPlanner.plan`.
    /// v2 added the ⌘K switcher; v3 added ⌘Q quit; v4 added ⌘C/⌘V/⌘X
    /// copy/paste/cut; v5 added ⌘A select-all and ⌘W close-window.
    static let currentVersion = 5

    func decode(_ data: Data) -> StoredKeybindingsPayload? {
        if let stored = try? JSONDecoder().decode(StoredKeybindingsPayload.self, from: data),
           (1...Self.currentVersion).contains(stored.version) {
            return stored
        }
        // Legacy: a bare array written before the versioned envelope existed.
        if let legacy = try? JSONDecoder().decode([Keybinding].self, from: data) {
            return StoredKeybindingsPayload(version: 1, bindings: legacy)
        }
        return nil
    }

    func encode(_ payload: StoredKeybindingsPayload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }
}
