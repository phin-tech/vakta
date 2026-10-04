//
//  ExtensionRegistryStoreShellTests.swift
//  VaktaIntegrationTests
//
//  Linking, Trust and persistence against real temporary directories, real
//  manifests and real build scripts.

import XCTest
@testable import Vakta

@MainActor
final class ExtensionRegistryStoreShellTests: XCTestCase {
    private var root: URL!
    private var extensionsDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionRegistryStoreShellTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("support", isDirectory: true)
        extensionsDirectory = base.appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeStore() -> ExtensionRegistryStore {
        ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, buildTimeout: 30)
    }

    /// An Extension directory whose build step writes `./run` (so the
    /// executable only exists after a build, like a compiled Extension).
    @discardableResult
    private func makeExtension(
        _ name: String, id: String? = nil, buildScript: String = "printf '#!/bin/sh\\necho v1\\n' > run && chmod +x run"
    ) throws -> URL {
        let directory = extensionsDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
            {"id": "\(id ?? name)", "name": "\(name.capitalized)", "command": ["./run", "serve"],
             "build": [["sh", "-c", "\(buildScript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"]],
             "panelViews": [{"id": "issues", "title": "Issues", "symbol": "checklist"}]}
            """
        try manifest.write(to: directory.appendingPathComponent(ExtensionManifest.fileName), atomically: true, encoding: .utf8)
        return directory
    }

    private func entry(_ store: ExtensionRegistryStore, _ directory: URL) -> ExtensionEntry? {
        store.entries.first { $0.record.directory == directory.standardizedFileURL.path }
    }

    // MARK: - Linking

    func test_link_addsAnUntrustedEntry_thatSurvivesRelaunch() throws {
        let directory = try makeExtension("kata")
        let store = makeStore()

        XCTAssertNil(store.link(directory: directory))

        XCTAssertEqual(entry(store, directory)?.manifest?.id, "kata")
        XCTAssertEqual(entry(store, directory)?.status, .needsApproval(.neverApproved))
        let relaunched = makeStore()
        XCTAssertEqual(entry(relaunched, directory)?.status, .needsApproval(.neverApproved))
    }

    func test_link_rejectsMissingOrInvalidManifest_andDuplicates() throws {
        let store = makeStore()
        let empty = extensionsDirectory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(store.link(directory: empty), .noManifest)

        let broken = extensionsDirectory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try #"{"id": "broken", "name": "B", "command": ["python3"]}"#
            .write(to: broken.appendingPathComponent(ExtensionManifest.fileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.link(directory: broken), .invalidManifest([
            "Command must start with a path inside the extension directory, like ./run.",
        ]))

        let first = try makeExtension("one", id: "same")
        let second = try makeExtension("two", id: "same")
        XCTAssertNil(store.link(directory: first))
        XCTAssertEqual(store.link(directory: first), .alreadyLinked)
        XCTAssertEqual(store.link(directory: second), .duplicateID("same"))
        XCTAssertEqual(store.entries.count, 1)
    }

    func test_unlink_removesThePersistedEntry() throws {
        let directory = try makeExtension("kata")
        let store = makeStore()
        store.link(directory: directory)

        store.unlink(directory.standardizedFileURL.path)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(makeStore().entries.isEmpty)
    }

    // MARK: - Trust

    func test_trust_runsTheBuildInTheExtensionDirectory_thenIsReady() async throws {
        let directory = try makeExtension("kata")
        let store = makeStore()
        store.link(directory: directory)

        let error = await store.trust(directory.standardizedFileURL.path)

        XCTAssertNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run").path))
        XCTAssertEqual(entry(store, directory)?.status, .ready)
        XCTAssertEqual(entry(makeStore(), directory)?.status, .ready)
    }

    func test_trust_failedBuild_grantsNothing() async throws {
        let directory = try makeExtension("kata", buildScript: "echo nope >&2; exit 3")
        let store = makeStore()
        store.link(directory: directory)

        let error = await store.trust(directory.standardizedFileURL.path)

        guard case .buildFailed? = error else { return XCTFail("expected buildFailed, got \(String(describing: error))") }
        XCTAssertEqual(entry(store, directory)?.status, .needsApproval(.neverApproved))
    }

    func test_trust_buildThatProducesNoExecutable_isMissingExecutable() async throws {
        let directory = try makeExtension("kata", buildScript: "true")
        let store = makeStore()
        store.link(directory: directory)

        let error = await store.trust(directory.standardizedFileURL.path)

        XCTAssertEqual(error, .missingExecutable("./run"))
        XCTAssertEqual(entry(store, directory)?.status, .needsApproval(.neverApproved))
    }

    func test_swappedExecutable_needsApproval_unlessDeveloperMode() async throws {
        let directory = try makeExtension("kata")
        let store = makeStore()
        store.link(directory: directory)
        await store.trust(directory.standardizedFileURL.path)

        try "#!/bin/sh\necho v2\n".write(to: directory.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertEqual(entry(store, directory)?.status, .needsApproval(.executableChanged))

        store.setDeveloperMode(true, for: directory.standardizedFileURL.path)
        await store.trust(directory.standardizedFileURL.path)
        try "#!/bin/sh\necho v3\n".write(to: directory.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertEqual(entry(store, directory)?.status, .ready)
    }

    func test_editedManifest_needsApproval() async throws {
        let directory = try makeExtension("kata")
        let store = makeStore()
        store.link(directory: directory)
        await store.trust(directory.standardizedFileURL.path)

        let manifestURL = directory.appendingPathComponent(ExtensionManifest.fileName)
        let edited = try String(contentsOf: manifestURL).replacingOccurrences(of: "\"serve\"", with: "\"serve\", \"--evil\"")
        try edited.write(to: manifestURL, atomically: true, encoding: .utf8)
        store.reload()

        XCTAssertEqual(entry(store, directory)?.status, .needsApproval(.manifestChanged))
    }

    func test_disabled_isNotReady_evenWhenTrusted() async throws {
        let directory = try makeExtension("kata")
        let store = makeStore()
        store.link(directory: directory)
        await store.trust(directory.standardizedFileURL.path)

        store.setEnabled(false, for: directory.standardizedFileURL.path)

        XCTAssertEqual(entry(store, directory)?.status, .disabled)
        XCTAssertEqual(entry(makeStore(), directory)?.status, .disabled)
    }

    func test_manifestDeletedAfterLinking_isInvalid_notRemoved() throws {
        let directory = try makeExtension("kata")
        let store = makeStore()
        store.link(directory: directory)

        try FileManager.default.removeItem(at: directory.appendingPathComponent(ExtensionManifest.fileName))
        store.reload()

        guard case .invalid? = entry(store, directory)?.status else {
            return XCTFail("expected invalid, got \(String(describing: entry(store, directory)?.status))")
        }
    }

    // MARK: - Persistence

    func test_corruptRegistry_loadsEmpty_andIsNotOverwritten() throws {
        let file = root.appendingPathComponent("extensions.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: file)

        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), garbage)
    }

    // MARK: - Built-in Extensions

    private func makeBuiltIn(_ name: String, marker: Bool, buildScript: String = "printf '#!/bin/sh\\necho hi\\n' > run && chmod +x run") throws -> URL {
        let builtIns = extensionsDirectory.appendingPathComponent("builtins", isDirectory: true)
        let directory = builtIns.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
            {"id": "\(name)", "name": "\(name.capitalized)", "command": ["./run"], "builtIn": \(marker),
             "build": [["sh", "-c", "\(buildScript.replacingOccurrences(of: "\"", with: "\\\""))"]]}
            """
        try manifest.write(to: directory.appendingPathComponent(ExtensionManifest.fileName), atomically: true, encoding: .utf8)
        return builtIns
    }

    func test_builtIn_isLinkedAutomatically_andReadyWithoutApproval_afterPreparing() async throws {
        let roots = try makeBuiltIn("github", marker: true)
        let store = ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, buildTimeout: 30, builtInRoots: [roots], builtInsRequireMarker: true)
        XCTAssertEqual(store.entries.map(\.manifest?.id), ["github"])
        XCTAssertTrue(store.entries.first?.record.builtIn == true)

        await store.prepareBuiltIns()

        XCTAssertTrue(FileManager.default.fileExists(atPath: roots.appendingPathComponent("github/run").path), "missing executable was built")
        XCTAssertEqual(store.entries.first?.status, .ready)
    }

    func test_builtIn_canBeDisabled_butNotUnlinked() throws {
        let roots = try makeBuiltIn("github", marker: true)
        let store = ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, builtInRoots: [roots], builtInsRequireMarker: true)
        let directory = try XCTUnwrap(store.entries.first?.record.directory)

        store.unlink(directory)
        XCTAssertEqual(store.entries.count, 1)

        store.setEnabled(false, for: directory)
        let relaunched = ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, builtInRoots: [roots], builtInsRequireMarker: true)
        XCTAssertEqual(relaunched.entries.first?.status, .disabled)
    }

    func test_developmentRoot_requiresTheBuiltInMarker() throws {
        let roots = try makeBuiltIn("kata", marker: false)
        let store = ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, builtInRoots: [roots], builtInsRequireMarker: true)
        XCTAssertTrue(store.entries.isEmpty)
        let bundled = ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, builtInRoots: [roots], builtInsRequireMarker: false)
        XCTAssertEqual(bundled.entries.map(\.manifest?.id), ["kata"], "inside the app bundle everything there is built in")
    }

    func test_builtInNoLongerShipped_isDropped() throws {
        let roots = try makeBuiltIn("github", marker: true)
        _ = ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, builtInRoots: [roots], builtInsRequireMarker: true)
        let without = ExtensionRegistryStore(root: root, path: { "/usr/bin:/bin" }, builtInRoots: [], builtInsRequireMarker: true)
        XCTAssertTrue(without.entries.isEmpty)
    }
}
