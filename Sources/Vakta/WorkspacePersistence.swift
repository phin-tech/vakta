//
//  WorkspacePersistence.swift
//  Vakta
//
//  Persists the set of open sessions so relaunching Vakta reopens them. Each
//  record is just enough to recreate a session and have it reconnect: which
//  profile, the multiplexer session name to attach-or-create, any user
//  rename, and any per-session working-directory override. The live terminal
//  isn't saved -- herdr/tmux keep the real session alive server-side, and the
//  record is what lets Vakta re-attach to it.

import Foundation

/// One persisted open session.
struct SessionRecord: Codable, Hashable {
    /// The profile to recreate the session from. If it no longer exists on
    /// restore, `WorkspaceStartupPlanner` reports the record as unresolved
    /// rather than substituting an unrelated profile.
    var profileID: Profile.ID
    /// The multiplexer session name (`{name}`), stable across restarts.
    var sessionName: String
    /// The user's rename, if any.
    var customName: String?
    /// An explicit per-session working-directory override, distinct from the
    /// profile's own default -- `nil` means "follow the profile," not "no
    /// working directory." `SessionStore.saveWorkspace` only sets this when
    /// the session's resolved directory differs from what its profile would
    /// currently produce, so restoring re-resolves from the (possibly since
    /// edited) profile rather than pinning a value the user never chose.
    /// Also `nil` on records written before this field existed.
    var workingDirectory: String?
}

/// Builds a `SessionRecord` from a live session's resolved fields. Pure
/// extraction of `SessionStore.saveWorkspace`'s working-directory diff: only
/// an explicit per-session override (one that differs from what `profiles`
/// says this record's profile currently produces) is worth pinning to the
/// record -- a value merely inherited from the profile should keep following
/// it if edited later, so it round-trips as `nil` here rather than being
/// baked in as if the user had chosen it.
enum SessionRecordBuilder {
    static func record(
        profileID: Profile.ID,
        sessionName: String,
        customName: String?,
        workingDirectory: String?,
        profiles: [Profile]
    ) -> SessionRecord {
        let inheritedFromProfile = profiles.first { $0.id == profileID }?.workingDirectory
        let explicitOverride = workingDirectory == inheritedFromProfile ? nil : workingDirectory
        return SessionRecord(
            profileID: profileID,
            sessionName: sessionName,
            customName: customName,
            workingDirectory: explicitOverride
        )
    }
}

/// The on-disk shape: the open-session records plus which one was selected.
/// A file written before `selectedSessionName` existed is a bare
/// `[SessionRecord]` array.
struct WorkspacePayload: Codable, Equatable {
    var records: [SessionRecord] = []
    var selectedSessionName: String?
}

/// Decodes/migrates the workspace file: the current `{records,
/// selectedSessionName}` envelope, or a legacy bare `[SessionRecord]` array
/// (no selection recorded). Any other shape (malformed JSON) is not
/// decodable -- the caller must preserve rather than reinterpret it.
struct WorkspaceFileCodec: FilePayloadCodec {
    func decode(_ data: Data) -> WorkspacePayload? {
        if let payload = try? JSONDecoder().decode(WorkspacePayload.self, from: data) {
            return payload
        }
        if let legacy = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            return WorkspacePayload(records: legacy, selectedSessionName: nil)
        }
        return nil
    }

    func encode(_ payload: WorkspacePayload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }
}

enum WorkspacePersistence {
    static func store(root: URL) -> PersistedFileStore<WorkspaceFileCodec> {
        PersistedFileStore(root: root, fileName: "workspace.json", codec: WorkspaceFileCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<WorkspacePayload> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ payload: WorkspacePayload, root: URL) -> FileSaveOutcome {
        store(root: root).save(payload)
    }
}
