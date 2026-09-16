//
//  ProfileMenuPlanner.swift
//  Vakta
//
//  Pure profile-menu projection and profile-deletion fallback. Previously
//  `AppDelegate.buildMainMenu` snapshotted `sessionStore.profiles` and
//  stored full `Profile` values as each menu item's `representedObject`
//  exactly once, at launch -- editing or deleting a profile afterward left
//  the app's menu bar using the stale command/arguments, or a since-deleted
//  profile, indefinitely. `SessionStore.deleteProfile` also let `profiles`
//  go permanently empty (and persist that way) if the last one was removed.

import Foundation

/// One "New Session" menu entry. Resolved back to a live `Profile` by `id`
/// at click time (see `AppDelegate.newSessionFromProfile`), never by a
/// value captured when the menu was built -- a stale action must not be
/// able to launch a deleted profile or an obsolete command snapshot.
struct ProfileMenuEntry: Equatable {
    var profileID: Profile.ID
    var title: String
}

enum ProfileMenuPlanner {
    /// Builds the current entries from `profiles`, in order. Called fresh
    /// each time the menu opens (an `NSMenuDelegate.menuNeedsUpdate`
    /// callback), not once at launch.
    static func entries(for profiles: [Profile]) -> [ProfileMenuEntry] {
        profiles.map { ProfileMenuEntry(profileID: $0.id, title: $0.name) }
    }
}

enum ProfileDeletionPlanner {
    /// `profiles` with `id` removed -- re-seeded to the built-in defaults
    /// instead of left empty if that removal would take the last one.
    /// `profiles` persists on every change (`SessionStore.profiles`'s
    /// `didSet`), so an empty result here would otherwise be a permanent,
    /// persisted "no profiles at all" state surviving every future restart,
    /// not just a harmless momentary gap `defaultProfile`'s in-memory
    /// `.herdr` fallback papers over.
    static func afterDeleting(_ id: Profile.ID, from profiles: [Profile]) -> [Profile] {
        let remaining = profiles.filter { $0.id != id }
        return remaining.isEmpty ? [.herdr, .tmux, .shell] : remaining
    }
}
