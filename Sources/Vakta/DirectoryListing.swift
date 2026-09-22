//
//  DirectoryListing.swift
//  Vakta
//
//  The file sidebar's pure ordering/visibility rules for one directory's
//  children, plus the value type its rows render. Kept free of the filesystem
//  so the sort/filter logic is testable in isolation; `DirectoryReader` does
//  the real read.
//

import Foundation

/// One entry in a directory -- a file or a subdirectory. `isDirectory`
/// follows a symlink's target (a link to a folder is a folder here) so the
/// tree can offer to expand it.
struct FileEntry: Equatable, Hashable {
    let name: String
    let isDirectory: Bool
}

enum DirectoryListing {
    /// Directories first, then files; case-insensitive alphabetical within
    /// each group; dotfiles hidden unless `showHidden`. A Finder-like default
    /// order that keeps folders grouped at the top.
    static func sorted(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        entries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
