//
//  HerdrConfigStore.swift
//  Vakta
//
//  Owner of the herdr config editor's state. The file on disk is the only
//  source of truth: `load()` adopts it, edits patch the in-memory document
//  (never disk), and `save()` runs the gate -- `herdr config check` on a temp
//  copy, an external-edit check, then backup + atomic write + reload. A
//  rejected or conflicted save leaves both the live file and the user's
//  pending edit untouched.

import Foundation

enum HerdrConfigStoreSaveResult: Equatable {
    case saved(reload: HerdrConfigReloadOutcome)
    case rejectedInvalid([HerdrConfigDiagnostic])
    case conflictExternalEdit
    case needsUnverifiedConfirmation
    case writeFailed(String)
}

@MainActor
final class HerdrConfigStore: ObservableObject {
    @Published private(set) var document = HerdrConfigDocument(text: "")
    @Published private(set) var isDirty = false
    @Published private(set) var loadError: String?

    private let file: HerdrConfigFile
    private let checker: HerdrConfigChecker
    private let reloader: HerdrConfigReloader
    private var baseFingerprint = HerdrConfigFingerprint.missing

    init(file: HerdrConfigFile, checker: HerdrConfigChecker, reloader: HerdrConfigReloader) {
        self.file = file
        self.checker = checker
        self.reloader = reloader
    }

    var fileURL: URL { file.url }
    var filePath: String { file.url.path }

    /// Asks the running herdr server to reload its config (no file change).
    func reloadServer() async -> HerdrConfigReloadOutcome {
        let reloader = self.reloader
        return await offMain { reloader.reload() }
    }

    /// Adopts whatever is on disk, discarding pending edits.
    func load() {
        switch file.load() {
        case .missing:
            document = HerdrConfigDocument(text: "")
            baseFingerprint = HerdrConfigFingerprint.missing
            loadError = nil
        case .loaded(let text, let fingerprint):
            document = HerdrConfigDocument(text: text)
            baseFingerprint = fingerprint
            loadError = nil
        case .unreadable(let message):
            loadError = message
        }
        isDirty = false
    }

    /// Replaces the whole document text (the Raw editor).
    func replaceText(_ text: String) {
        guard text != document.text else { return }
        document = HerdrConfigDocument(text: text)
        isDirty = true
    }

    /// Applies a pure document transform (array-table edits and the like).
    func apply(_ transform: (HerdrConfigDocument) -> HerdrConfigDocument) {
        let updated = transform(document)
        guard updated.text != document.text else { return }
        document = updated
        isDirty = true
    }

    func set(_ path: String, to value: HerdrConfigValue) {
        document = document.setting(path, to: value)
        isDirty = true
    }

    func unset(_ path: String) {
        document = document.unsetting(path)
        isDirty = true
    }

    func save(confirmUnverified: Bool = false) async -> HerdrConfigStoreSaveResult {
        let candidate = document.text
        let checker = self.checker
        let check = await offMain { checker.check(candidate: candidate) }

        let current: String
        switch file.load() {
        case .missing: current = HerdrConfigFingerprint.missing
        case .loaded(_, let fingerprint): current = fingerprint
        case .unreadable(let message): return .writeFailed(message)
        }

        switch HerdrConfigSavePlanner.decide(
            baseFingerprint: baseFingerprint, currentFingerprint: current, check: check
        ) {
        case .rejectInvalid(let diagnostics): return .rejectedInvalid(diagnostics)
        case .conflictExternalEdit: return .conflictExternalEdit
        case .needsUnverifiedConfirmation where !confirmUnverified: return .needsUnverifiedConfirmation
        case .needsUnverifiedConfirmation, .save: break
        }

        if case .failure(let error) = file.save(candidate) {
            return .writeFailed(error.localizedDescription)
        }
        baseFingerprint = HerdrConfigFingerprint.of(candidate)
        isDirty = false

        let reloader = self.reloader
        return .saved(reload: await offMain { reloader.reload() })
    }

    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
