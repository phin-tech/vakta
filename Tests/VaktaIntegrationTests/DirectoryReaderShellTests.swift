//
//  DirectoryReaderShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases proving `DirectoryReader.children` reads a real directory into
//  the `FileEntry` values the sidebar tree renders, and fails soft (nil) on a
//  path it can't read -- against a temporary directory, never the user's files.
//

import XCTest
@testable import Vakta

final class DirectoryReaderShellTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryReaderShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_readsNamesAndDirectoryFlags() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: root.appendingPathComponent("readme.md"))

        let entries = try XCTUnwrap(DirectoryReader.children(of: root.path))

        XCTAssertEqual(
            Set(entries),
            [FileEntry(name: "src", isDirectory: true), FileEntry(name: "readme.md", isDirectory: false)]
        )
    }

    func test_symlinkToDirectory_isReportedAsDirectory() throws {
        let realDir = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: realDir)

        let entries = try XCTUnwrap(DirectoryReader.children(of: root.path))
        let link = try XCTUnwrap(entries.first { $0.name == "link" })
        XCTAssertTrue(link.isDirectory, "a symlink pointing at a directory should list as a directory")
    }

    func test_missingPath_isNil() {
        XCTAssertNil(DirectoryReader.children(of: root.appendingPathComponent("does-not-exist").path))
    }

    func test_fileInsteadOfDirectory_isNil() throws {
        let file = root.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(DirectoryReader.children(of: file.path))
    }
}
