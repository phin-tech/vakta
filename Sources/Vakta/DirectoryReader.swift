//
//  DirectoryReader.swift
//  Vakta
//
//  The filesystem read behind the file sidebar tree: one directory's children
//  as `FileEntry` values. Fails soft (nil) for a path that isn't a readable
//  directory so the tree can keep a node collapsed rather than crash. The
//  caller owns dispatching this off the main actor.
//

import Foundation

enum DirectoryReader {
    /// The children of `path`, or `nil` if it isn't a directory or can't be
    /// read. `isDirectory` resolves symlinks (a link to a folder counts as a
    /// folder) so the tree offers to expand it.
    static func children(of path: String) -> [FileEntry]? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return nil }

        return contents.map { child in
            // `fileExists(isDirectory:)` follows symlinks, so a link to a
            // folder reads as a directory (and a broken link reads as a file).
            var flag: ObjCBool = false
            let isDir = fileManager.fileExists(atPath: child.path, isDirectory: &flag) && flag.boolValue
            return FileEntry(name: child.lastPathComponent, isDirectory: isDir)
        }
    }
}
