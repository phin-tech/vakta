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
    /// Bumped on every `load()`. Views key their identity on it so local text
    /// drafts are rebuilt from the document after a discard/reload.
    @Published private(set) var loadGeneration = 0

    /// How long an edit must sit untouched before `autoSaveIfDue` will save
    /// it -- a burst of edits (typing, a Reset Section click) keeps pushing
    /// this out via `noteEdited`, so it fires once after the burst settles
    /// rather than once per keystroke.
    static let autoSaveDebounceInterval: TimeInterval = 1.5
    private static let autoSaveDebouncer = WorkspaceRefreshDebouncer(debounceInterval: autoSaveDebounceInterval, minInterval: 0)

    private let file: HerdrConfigFile
    private let checker: HerdrConfigChecker
    private let reloader: HerdrConfigReloader
    private var baseFingerprint = HerdrConfigFingerprint.missing
    /// When the next `autoSaveIfDue` call should actually save, or nil
    /// between edits (idle) and right after an attempt (whether or not it
    /// actually saved -- a rejected/unverified attempt waits for the next
    /// edit rather than retrying on every poll).
    private var pendingAutoSaveFireDate: Date?

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

    /// Re-reads the file only if it changed on disk and there are no pending
    /// edits. Opening the pane calls this instead of `load()` so an unchanged
    /// file doesn't bump `loadGeneration` and rebuild every row.
    func reloadIfChangedOnDisk() {
        guard !isDirty else { return }
        let current: String
        switch file.load() {
        case .missing: current = HerdrConfigFingerprint.missing
        case .loaded(_, let fingerprint): current = fingerprint
        case .unreadable: return
        }
        if current != baseFingerprint { load() }
    }

    /// Adopts whatever is on disk, discarding pending edits.
    func load() {
        defer { loadGeneration += 1 }
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
        noteEdited()
    }

    /// Applies a pure document transform (array-table edits and the like).
    func apply(_ transform: (HerdrConfigDocument) -> HerdrConfigDocument) {
        let updated = transform(document)
        guard updated.text != document.text else { return }
        document = updated
        isDirty = true
        noteEdited()
    }

    func set(_ path: String, to value: HerdrConfigValue) {
        document = document.setting(path, to: value)
        isDirty = true
        noteEdited()
    }

    func unset(_ path: String) {
        document = document.unsetting(path)
        isDirty = true
        noteEdited()
    }

    /// Pushes out the pending auto-save fire date -- called on every edit
    /// (directly by the mutators above; tests also call it with a controlled
    /// `now` to drive `autoSaveIfDue` deterministically).
    func noteEdited(now: Date = Date()) {
        pendingAutoSaveFireDate = Self.autoSaveDebouncer.scheduledFireDate(now: now, lastFireDate: nil)
    }

    /// Saves if an edit's debounce has elapsed. A no-op while clean or not
    /// yet due. Runs the same gate as a manual Save -- in particular, an
    /// unverifiable config (`herdr config check` unavailable) is never
    /// auto-confirmed; it stays dirty until the user clicks "Save anyway".
    /// Returns nil without attempting anything while clean or not yet due --
    /// callers (the Preferences pane's poll) use that to leave whatever
    /// save-result message is already on screen alone, rather than clearing
    /// it on every poll tick.
    @discardableResult
    func autoSaveIfDue(now: Date = Date()) async -> HerdrConfigStoreSaveResult? {
        guard isDirty, let fireDate = pendingAutoSaveFireDate, now >= fireDate else { return nil }
        pendingAutoSaveFireDate = nil
        return await save(confirmUnverified: false)
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
