//
//  ExtensionRegistryStore.swift
//  Vakta
//
//  Owns the Linked Extensions list: linking directories, reading their
//  manifests, granting Trust (build, then fingerprint), developer mode and
//  enabling. Decisions live in ExtensionManifest / TrustEvaluator; this type
//  does the file and process I/O and publishes the result.

import Foundation

enum ExtensionStatus: Equatable {
    /// Trusted and enabled: may run.
    case ready
    case disabled
    case needsApproval(TrustReason)
    /// The manifest is missing, unreadable or has problems.
    case invalid([String])
}

struct ExtensionEntry: Identifiable, Equatable {
    var id: String { record.directory }
    var record: LinkedExtensionRecord
    var manifest: ExtensionManifest?
    var status: ExtensionStatus

    var directoryURL: URL { URL(fileURLWithPath: record.directory, isDirectory: true) }
    var displayName: String { manifest?.name ?? directoryURL.lastPathComponent }
}

enum ExtensionLinkError: Error, Equatable {
    case alreadyLinked
    case noManifest
    case invalidManifest([String])
    case duplicateID(String)
}

enum ExtensionTrustError: Error, Equatable {
    case notLinked
    case invalidManifest([String])
    /// A build command failed; carries the command and a short reason.
    case buildFailed(command: String, reason: String)
    case missingExecutable(String)
    case saveFailed
}

@MainActor
final class ExtensionRegistryStore: ObservableObject {
    static let fileName = "extensions.json"

    @Published private(set) var entries: [ExtensionEntry] = []

    private let root: URL
    private let path: @MainActor () -> String
    private let buildTimeout: TimeInterval
    private var registry: ExtensionRegistry

    private var file: PersistedFileStore<ExtensionRegistryFileCodec> {
        PersistedFileStore(root: root, fileName: Self.fileName, codec: ExtensionRegistryFileCodec())
    }

    /// `path` supplies PATH for build commands, read when a build starts
    /// (the login shell's PATH may still be resolving at launch). It must not
    /// block: it runs on the main actor.
    init(root: URL, path: @escaping @MainActor () -> String, buildTimeout: TimeInterval = 900) {
        self.root = root
        self.path = path
        self.buildTimeout = buildTimeout
        // A corrupt or unreadable file loads as empty for this run and is not
        // rewritten until the user changes something.
        if case .loaded(let loaded) = PersistedFileStore(
            root: root, fileName: Self.fileName, codec: ExtensionRegistryFileCodec()
        ).load() {
            registry = loaded
        } else {
            registry = ExtensionRegistry(records: [])
        }
        reload()
    }

    /// `nil` on success.
    @discardableResult
    func link(directory: URL) -> ExtensionLinkError? {
        let path = directory.standardizedFileURL.path
        guard !registry.records.contains(where: { $0.directory == path }) else { return .alreadyLinked }
        guard let data = try? Data(contentsOf: Self.manifestURL(path)) else { return .noManifest }
        guard let manifest = ExtensionManifest.decode(data) else { return .invalidManifest([Self.undecodableManifest]) }
        let problems = manifest.problems
        guard problems.isEmpty else { return .invalidManifest(problems) }
        guard !entries.contains(where: { $0.manifest?.id == manifest.id }) else { return .duplicateID(manifest.id) }

        registry.records.append(LinkedExtensionRecord(directory: path, enabled: true, developerMode: false, approved: nil))
        persist()
        return nil
    }

    func unlink(_ directory: String) {
        registry.records.removeAll { $0.directory == directory }
        persist()
    }

    func setEnabled(_ enabled: Bool, for directory: String) {
        update(directory) { $0.enabled = enabled }
    }

    func setDeveloperMode(_ developerMode: Bool, for directory: String) {
        update(directory) { $0.developerMode = developerMode }
    }

    func setNotifications(_ notifications: Bool, for directory: String) {
        update(directory) { $0.notifications = notifications }
    }

    /// Runs the manifest's build commands, then records approval of what is
    /// on disk. Only call after the user approved the manifest.
    /// `nil` on success.
    @discardableResult
    func trust(_ directory: String) async -> ExtensionTrustError? {
        guard registry.records.contains(where: { $0.directory == directory }) else { return .notLinked }
        // Approve the manifest bytes as read now: if the build rewrote the
        // manifest, the next evaluation shows it as changed.
        guard let manifestData = try? Data(contentsOf: Self.manifestURL(directory)),
              let manifest = ExtensionManifest.decode(manifestData)
        else { return .invalidManifest([Self.undecodableManifest]) }
        guard manifest.problems.isEmpty else { return .invalidManifest(manifest.problems) }

        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let environment = ["PATH": path(), "HOME": NSHomeDirectory()]
        let timeout = buildTimeout
        for command in manifest.build {
            let result = await Task.detached {
                BoundedProcessRunner.run(
                    executable: "/usr/bin/env", arguments: command, environment: environment,
                    timeout: timeout, currentDirectory: directoryURL
                )
            }.value
            if let reason = Self.buildFailure(result) {
                return .buildFailed(command: command.joined(separator: " "), reason: reason)
            }
        }

        guard let executableURL = manifest.executableURL(in: directoryURL),
              let executable = try? Data(contentsOf: executableURL)
        else { return .missingExecutable(manifest.command[0]) }

        guard let index = registry.records.firstIndex(where: { $0.directory == directory }) else { return .notLinked }
        let current = TrustFingerprint.make(manifest: manifestData, executable: executable)
        registry.records[index].approved = TrustEvaluator.approval(
            of: current, developerMode: registry.records[index].developerMode
        )
        guard case .success = persist() else { return .saveFailed }
        return nil
    }

    /// Re-reads manifests and executables and re-evaluates Trust.
    func reload() {
        entries = registry.records.map(Self.entry)
    }

    // MARK: - Private

    private static let undecodableManifest = "\(ExtensionManifest.fileName) isn't a valid manifest."

    private static func manifestURL(_ directory: String) -> URL {
        URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(ExtensionManifest.fileName)
    }

    private static func entry(for record: LinkedExtensionRecord) -> ExtensionEntry {
        guard let data = try? Data(contentsOf: manifestURL(record.directory)) else {
            return ExtensionEntry(record: record, manifest: nil, status: .invalid(["\(ExtensionManifest.fileName) is missing."]))
        }
        guard let manifest = ExtensionManifest.decode(data) else {
            return ExtensionEntry(record: record, manifest: nil, status: .invalid([undecodableManifest]))
        }
        let problems = manifest.problems
        guard problems.isEmpty else {
            return ExtensionEntry(record: record, manifest: manifest, status: .invalid(problems))
        }
        guard record.enabled else { return ExtensionEntry(record: record, manifest: manifest, status: .disabled) }

        let executable = manifest.executableURL(in: URL(fileURLWithPath: record.directory, isDirectory: true))
            .flatMap { try? Data(contentsOf: $0) }
        let current = TrustFingerprint.make(manifest: data, executable: executable)
        switch TrustEvaluator.evaluate(approved: record.approved, current: current, developerMode: record.developerMode) {
        case .trusted: return ExtensionEntry(record: record, manifest: manifest, status: .ready)
        case .needsApproval(let reason): return ExtensionEntry(record: record, manifest: manifest, status: .needsApproval(reason))
        }
    }

    private static func buildFailure(_ result: ProcessResult) -> String? {
        switch result {
        case .success, .invalidUTF8: return nil
        case .launchFailed: return "couldn't start"
        case .nonZeroExit(let code): return "exited with status \(code)"
        case .timedOut: return "timed out"
        case .cancelled: return "was cancelled"
        }
    }

    private func update(_ directory: String, _ change: (inout LinkedExtensionRecord) -> Void) {
        guard let index = registry.records.firstIndex(where: { $0.directory == directory }) else { return }
        change(&registry.records[index])
        persist()
    }

    @discardableResult
    private func persist() -> FileSaveOutcome {
        let outcome = file.save(registry)
        reload()
        return outcome
    }
}
