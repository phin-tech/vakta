//
//  WorkingDirectoryResolver.swift
//  Vakta
//
//  Which of "Open in Editor"'s three cwd signals to trust, in order: a
//  multiplexer's active-pane query, OSC-7's `viewState.workingDirectory`
//  (already wired via libghostty, previously unread by Vakta), and the
//  profile's launch-time `workingDirectory` (stale after a `cd`, only
//  meaningful for a plain, non-multiplexer shell). Pure -- operates on a
//  snapshot, no `Session`/`Profile`/`SessionStore` dependency.

import Foundation

enum WorkingDirectoryResolver {
    static func resolve(
        multiplexerResult: ActivePaneWorkingDirectoryResult?,
        terminalReportedWorkingDirectory: String?,
        profileWorkingDirectory: String?
    ) -> String? {
        if case .workingDirectory(let path)? = multiplexerResult {
            return path
        }
        if let terminalReportedWorkingDirectory, !terminalReportedWorkingDirectory.isEmpty {
            return terminalReportedWorkingDirectory
        }
        return profileWorkingDirectory
    }
}
