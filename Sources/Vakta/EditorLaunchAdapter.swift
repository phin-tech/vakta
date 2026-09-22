//
//  EditorLaunchAdapter.swift
//  Vakta
//
//  The only AppKit/`NSWorkspace` boundary "Open in Editor" touches --
//  installed-editor discovery and the actual launch. Deliberately thin and
//  untested (per docs/testing.md's accepted-0%-coverage wiring rationale,
//  same as `AppearanceStore.apply()`'s one `NSApp.appearance =` side
//  effect): every decision lives in `OpenInEditorPlanner`, which takes the
//  installed set as plain input instead of calling `NSWorkspace` itself.

import AppKit

enum EditorLaunchAdapter {
    /// Which `EditorChoice` cases have an installed application -- input to
    /// `OpenInEditorPlanner`. A choice with no `bundleIdentifier` (`.auto`)
    /// or an unresolvable one (a wrong/stale id) is simply absent, not an
    /// error.
    static func installedEditors() -> Set<EditorChoice> {
        Set(EditorChoice.allCases.filter { choice in
            guard let bundleIdentifier = choice.bundleIdentifier else { return false }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        })
    }

    /// Opens `directory` with `editor`. A no-op if `editor`'s app can no
    /// longer be resolved -- `OpenInEditorPlanner` already checked
    /// `installedEditors()` before choosing it, but the app could have been
    /// removed between that snapshot and this call; degrading to nothing is
    /// preferable to crashing.
    static func open(_ directory: String, with editor: EditorChoice) {
        guard let bundleIdentifier = editor.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        NSWorkspace.shared.open([directoryURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens a specific file (or directory) `url` with `editor`. A no-op if the
    /// editor's app can't be resolved.
    static func open(url: URL, with editor: EditorChoice) {
        guard let bundleIdentifier = editor.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens `url` in the user's configured editor: the explicit `choice` when
    /// it's installed, otherwise the same first-installed fallback `.auto`
    /// uses, and only if no editor is installed does it fall back to the
    /// system default app for the file. This is what the file sidebar's "Open"
    /// runs so a file lands in the editor, not Preview/Xcode-by-extension.
    static func openFile(_ url: URL, choice: EditorChoice) {
        let installed = installedEditors()
        let editor: EditorChoice? = (choice != .auto && installed.contains(choice))
            ? choice
            : OpenInEditorPlanner.autoFallback(installedEditors: installed)
        if let editor {
            open(url: url, with: editor)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
