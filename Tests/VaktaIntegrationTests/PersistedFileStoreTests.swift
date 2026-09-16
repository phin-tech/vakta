//
//  PersistedFileStoreTests.swift
//  VaktaIntegrationTests
//
//  Shell/integration cases for `PersistedFileStore`: real files in a
//  temporary directory injected as `root`, never real Application Support.
//  Part of kata issue k916 (shared persistence boundary).

import XCTest
@testable import Vakta

final class PersistedFileStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeStore() -> PersistedFileStore<JSONCodec<NotificationSettings>> {
        PersistedFileStore(root: tempDirectory, fileName: "notifications.json", codec: JSONCodec())
    }

    func test_load_whenFileAbsent_returnsMissing() {
        let store = makeStore()
        guard case .missing = store.load() else {
            return XCTFail("expected .missing for a never-written file")
        }
    }

    func test_load_afterSave_roundTripsThePayload() {
        let store = makeStore()
        let settings = NotificationSettings(notifyOnAttention: false, notifyOnFinished: true, bounceDock: false)

        guard case .success = store.save(settings) else {
            return XCTFail("expected save to succeed")
        }

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("expected .loaded after a successful save")
        }
        XCTAssertEqual(loaded, settings)
    }

    func test_save_writesAtomically_noStrayTemporaryFilesRemain() {
        let store = makeStore()
        guard case .success = store.save(NotificationSettings()) else {
            return XCTFail("expected save to succeed")
        }

        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
        XCTAssertEqual(siblings, ["notifications.json"], "atomic write must not leave temp/backup artifacts behind")
    }

    func test_load_corruptFile_returnsCorruptWithOriginalBytesPreserved() throws {
        let store = makeStore()
        let corruptBytes = Data("{ not valid json".utf8)
        try corruptBytes.write(to: store.fileURL)

        guard case .corrupt(let bytes) = store.load() else {
            return XCTFail("expected .corrupt for an undecodable file")
        }
        XCTAssertEqual(bytes, corruptBytes)

        // Loading again must not have overwritten the corrupt file with a
        // freshly seeded default -- the original bytes must still be on disk.
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corruptBytes)
    }

    func test_load_unreadableFile_returnsUnreadableWithoutModifyingIt() throws {
        let store = makeStore()
        let originalBytes = try JSONEncoder().encode(NotificationSettings())
        try originalBytes.write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        }

        guard case .unreadable = store.load() else {
            return XCTFail("expected .unreadable for a file with no read permission")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalBytes)
    }

    func test_save_whenRootDirectoryMissing_returnsFailureRatherThanCrashingOrFallingBackElsewhere() {
        let missingRoot = tempDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
        let store = PersistedFileStore(root: missingRoot, fileName: "notifications.json", codec: JSONCodec<NotificationSettings>())

        guard case .failure = store.save(NotificationSettings()) else {
            return XCTFail("expected .failure when the injected root does not exist")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingRoot.path),
            "a failed save must not silently create/fall back to a different location"
        )
    }

    func test_fileURL_usesOnlyTheInjectedRoot() {
        let store = makeStore()
        XCTAssertEqual(store.fileURL, tempDirectory.appendingPathComponent("notifications.json"))
    }
}
