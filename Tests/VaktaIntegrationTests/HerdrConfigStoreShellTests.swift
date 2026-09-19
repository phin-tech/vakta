//
//  HerdrConfigStoreShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for the herdr config editor's I/O boundary: file load/save,
//  the `herdr config check` gate, the reload step, and the store that ties
//  them together. Uses a real temp directory and a real fixture executable
//  standing in for `herdr` (never the user's config, never a live server).
//  See docs/herdr-config-gui-plan.md, phase 2.

import XCTest
@testable import Vakta

@MainActor
final class HerdrConfigStoreShellTests: XCTestCase {
    private var tempDirectory: URL!
    private var configURL: URL!
    private var outputDirectory: URL!
    private var fixtureHerdr: String!
    private var clockTick = 0

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrConfigStoreShellTests-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = tempDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        configURL = tempDirectory.appendingPathComponent("herdr", isDirectory: true)
            .appendingPathComponent("config.toml")

        // Stand-in `herdr`: `config check` records the path it was pointed at
        // and rejects any config containing "sideways" with real-format
        // output and exit 1; `server reload-config` leaves a marker (or
        // fails if $OUT/fail-reload exists).
        let script = tempDirectory.appendingPathComponent("herdr-fixture.sh")
        try #"""
        #!/bin/sh
        case "$1 $2" in
        "config check")
            printf '%s\n' "$HERDR_CONFIG_PATH" > "$OUT/checked-path"
            if grep -q sideways "$HERDR_CONFIG_PATH"; then
                printf 'config: issues found\nconfig parse error: TOML parse error at line 2, column 20\n  |\n2 | tab_bar_position = "sideways"\n  |                    ^^^^^^^^^^\nunknown variant `sideways`, expected `top` or `bottom`\n; using defaults\n'
                exit 1
            fi
            echo "config: ok"
            ;;
        "server reload-config")
            [ -e "$OUT/fail-reload" ] && exit 3
            : > "$OUT/reloaded"
            ;;
        esac
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        fixtureHerdr = script.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: helpers

    private func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func liveConfig() -> String? {
        try? String(contentsOf: configURL, encoding: .utf8)
    }

    private func outputExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent(name).path)
    }

    private func backups() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: configURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.lastPathComponent.hasPrefix("config.toml.bak-vakta-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeStore(herdr: [String]? = nil, backupsToKeep: Int = 5) -> HerdrConfigStore {
        let command = herdr ?? [fixtureHerdr]
        let environment = ["OUT": outputDirectory.path]
        return HerdrConfigStore(
            file: HerdrConfigFile(url: configURL, backupsToKeep: backupsToKeep, now: { [unowned self] in
                clockTick += 1
                return Date(timeIntervalSince1970: 1_800_000_000 + Double(clockTick))
            }),
            checker: HerdrConfigChecker(herdrCommand: command, path: "/usr/bin:/bin", environment: environment),
            reloader: HerdrConfigReloader(herdrCommand: command, path: "/usr/bin:/bin", environment: environment)
        )
    }

    // MARK: file

    func test_file_missing_loadsAsEmptyAndCreatesNothing() {
        let file = HerdrConfigFile(url: configURL, backupsToKeep: 5, now: Date.init)
        XCTAssertEqual(file.load(), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func test_file_save_createsMissingDirectoryAndWritesExactBytes() throws {
        let file = HerdrConfigFile(url: configURL, backupsToKeep: 5, now: Date.init)
        guard case .success = file.save("[ui]\r\nconfirm_close = false\r\n") else {
            return XCTFail("save into a missing directory must succeed")
        }
        XCTAssertEqual(liveConfig(), "[ui]\r\nconfirm_close = false\r\n")
        XCTAssertTrue(backups().isEmpty, "nothing existed to back up")
    }

    func test_file_save_overExistingFile_backsUpPreviousBytesFirst() throws {
        try writeConfig("old = 1\n")
        let file = HerdrConfigFile(url: configURL, backupsToKeep: 5, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = file.save("new = 2\n")
        XCTAssertEqual(liveConfig(), "new = 2\n")
        let found = backups()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(try String(contentsOf: found[0], encoding: .utf8), "old = 1\n")
    }

    func test_file_save_prunesBackupsToTheMostRecentN() throws {
        try writeConfig("v0\n")
        let file = HerdrConfigFile(url: configURL, backupsToKeep: 2, now: { [unowned self] in
            clockTick += 1
            return Date(timeIntervalSince1970: 1_800_000_000 + Double(clockTick))
        })
        for version in 1...4 { _ = file.save("v\(version)\n") }
        let found = backups()
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(try String(contentsOf: found[0], encoding: .utf8), "v2\n")
        XCTAssertEqual(try String(contentsOf: found[1], encoding: .utf8), "v3\n")
    }

    func test_file_load_returnsTextAndContentFingerprint() throws {
        try writeConfig("a = 1\n")
        let file = HerdrConfigFile(url: configURL, backupsToKeep: 5, now: Date.init)
        guard case .loaded(let text, let fingerprint) = file.load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(text, "a = 1\n")
        XCTAssertEqual(fingerprint, HerdrConfigFingerprint.of("a = 1\n"))
        XCTAssertNotEqual(fingerprint, HerdrConfigFingerprint.of("a = 2\n"))
    }

    // MARK: checker

    func test_checker_validCandidate_isValid_andRunsAgainstATempCopyNotTheLiveFile() throws {
        try writeConfig("live = 1\n")
        let checker = HerdrConfigChecker(
            herdrCommand: [fixtureHerdr], path: "/usr/bin:/bin", environment: ["OUT": outputDirectory.path])
        XCTAssertEqual(checker.check(candidate: "[ui]\nconfirm_close = false\n"), .valid)
        let checkedPath = try String(contentsOf: outputDirectory.appendingPathComponent("checked-path"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(checkedPath, configURL.path)
        XCTAssertEqual(liveConfig(), "live = 1\n")
    }

    func test_checker_invalidCandidate_returnsParsedDiagnosticFromNonZeroExit() {
        let checker = HerdrConfigChecker(
            herdrCommand: [fixtureHerdr], path: "/usr/bin:/bin", environment: ["OUT": outputDirectory.path])
        XCTAssertEqual(
            checker.check(candidate: "[ui]\ntab_bar_position = \"sideways\"\n"),
            .invalid([HerdrConfigDiagnostic(
                line: 2, column: 20, message: "unknown variant `sideways`, expected `top` or `bottom`")])
        )
    }

    func test_checker_missingExecutable_isUnavailableNotInvalid() {
        let checker = HerdrConfigChecker(
            herdrCommand: ["/nonexistent/herdr"], path: "/usr/bin:/bin", environment: [:])
        XCTAssertEqual(checker.check(candidate: "a = 1\n"), .unavailable)
    }

    // MARK: reloader

    func test_reloader_success_andFailureAreDistinguished() throws {
        let reloader = HerdrConfigReloader(
            herdrCommand: [fixtureHerdr], path: "/usr/bin:/bin", environment: ["OUT": outputDirectory.path])
        XCTAssertEqual(reloader.reload(), .reloaded)
        XCTAssertTrue(outputExists("reloaded"))

        try Data().write(to: outputDirectory.appendingPathComponent("fail-reload"))
        guard case .failed = reloader.reload() else { return XCTFail("nonzero exit must be .failed") }
    }

    func test_reloader_missingExecutable_isFailed() {
        let reloader = HerdrConfigReloader(
            herdrCommand: ["/nonexistent/herdr"], path: "/usr/bin:/bin", environment: [:])
        guard case .failed = reloader.reload() else { return XCTFail("missing herdr must be .failed") }
    }

    // MARK: store

    func test_store_load_missingFile_startsEmptyAndCleanWithoutCreatingTheFile() {
        let store = makeStore()
        store.load()
        XCTAssertEqual(store.document.text, "")
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func test_store_edit_marksDirty_withoutTouchingDisk() throws {
        try writeConfig("[ui]\nconfirm_close = true\n")
        let store = makeStore()
        store.load()
        store.set("ui.confirm_close", to: .bool(false))
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.document.value(at: "ui.confirm_close"), .bool(false))
        XCTAssertEqual(liveConfig(), "[ui]\nconfirm_close = true\n")
    }

    func test_store_save_writesBacksUpReloadsAndBecomesClean() async throws {
        try writeConfig("# mine\n[ui]\nconfirm_close = true\n")
        let store = makeStore()
        store.load()
        store.set("ui.confirm_close", to: .bool(false))

        let result = await store.save()

        XCTAssertEqual(result, .saved(reload: .reloaded))
        XCTAssertEqual(liveConfig(), "# mine\n[ui]\nconfirm_close = false\n")
        XCTAssertEqual(backups().count, 1)
        XCTAssertTrue(outputExists("reloaded"))
        XCTAssertFalse(store.isDirty)
    }

    func test_store_save_twiceInARow_doesNotSelfConflict() async throws {
        try writeConfig("[ui]\nconfirm_close = true\n")
        let store = makeStore()
        store.load()
        store.set("ui.confirm_close", to: .bool(false))
        _ = await store.save()
        store.set("ui.confirm_close", to: .bool(true))
        let second = await store.save()
        XCTAssertEqual(second, .saved(reload: .reloaded))
        XCTAssertEqual(liveConfig(), "[ui]\nconfirm_close = true\n")
    }

    func test_store_save_invalidValue_isRejected_liveFileUntouched_noReload() async throws {
        try writeConfig("[ui]\ntab_bar_position = \"top\"\n")
        let store = makeStore()
        store.load()
        store.set("ui.tab_bar_position", to: .string("sideways"))

        let result = await store.save()

        XCTAssertEqual(result, .rejectedInvalid([HerdrConfigDiagnostic(
            line: 2, column: 20, message: "unknown variant `sideways`, expected `top` or `bottom`")]))
        XCTAssertEqual(liveConfig(), "[ui]\ntab_bar_position = \"top\"\n")
        XCTAssertFalse(outputExists("reloaded"))
        XCTAssertTrue(store.isDirty, "the user's edit must survive a rejected save")
    }

    func test_store_save_externalEditSinceLoad_isConflict_andExternalBytesPreserved() async throws {
        try writeConfig("[ui]\nconfirm_close = true\n")
        let store = makeStore()
        store.load()
        store.set("ui.confirm_close", to: .bool(false))
        try writeConfig("[ui]\nconfirm_close = true\n# edited by herdr\n")

        let result = await store.save()

        XCTAssertEqual(result, .conflictExternalEdit)
        XCTAssertEqual(liveConfig(), "[ui]\nconfirm_close = true\n# edited by herdr\n")
        XCTAssertTrue(backups().isEmpty)
    }

    func test_store_reloadFromDisk_afterConflict_adoptsExternalTextAndClearsDirty() async throws {
        try writeConfig("a = 1\n")
        let store = makeStore()
        store.load()
        store.set("a", to: .integer(2))
        try writeConfig("a = 1\nb = 3\n")
        _ = await store.save()

        store.load()

        XCTAssertEqual(store.document.text, "a = 1\nb = 3\n")
        XCTAssertFalse(store.isDirty)
    }

    func test_store_save_herdrMissing_needsConfirmation_thenSavesUnverifiedWhenConfirmed() async throws {
        try writeConfig("a = 1\n")
        let store = makeStore(herdr: ["/nonexistent/herdr"])
        store.load()
        store.set("a", to: .integer(2))

        let first = await store.save()
        XCTAssertEqual(first, .needsUnverifiedConfirmation)
        XCTAssertEqual(liveConfig(), "a = 1\n")

        let confirmed = await store.save(confirmUnverified: true)
        guard case .saved(let reload) = confirmed, case .failed = reload else {
            return XCTFail("confirmed save must write the file and report reload failure, got \(confirmed)")
        }
        XCTAssertEqual(liveConfig(), "a = 2\n")
    }

    func test_store_save_reloadFailure_stillSavesFile_andReportsFailure() async throws {
        try writeConfig("a = 1\n")
        try Data().write(to: outputDirectory.appendingPathComponent("fail-reload"))
        let store = makeStore()
        store.load()
        store.set("a", to: .integer(2))

        let result = await store.save()

        guard case .saved(let reload) = result, case .failed = reload else {
            return XCTFail("expected saved-with-failed-reload, got \(result)")
        }
        XCTAssertEqual(liveConfig(), "a = 2\n")
        XCTAssertFalse(store.isDirty)
    }

    func test_store_save_writeFailure_isReported_andStaysDirty() async throws {
        try writeConfig("a = 1\n")
        let store = makeStore()
        store.load()
        store.set("a", to: .integer(2))
        // Make the config's directory unwritable so the atomic write fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: configURL.deletingLastPathComponent().path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: configURL.deletingLastPathComponent().path)
        }

        let result = await store.save()

        guard case .writeFailed = result else { return XCTFail("expected writeFailed, got \(result)") }
        XCTAssertTrue(store.isDirty)
        XCTAssertFalse(outputExists("reloaded"))
    }

    func test_store_replaceText_adoptsRawEditsAsDirty_andSavesThemVerbatim() async throws {
        try writeConfig("a = 1\n")
        let store = makeStore()
        store.load()
        store.replaceText("# raw edit\na = 5\n")
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.document.value(at: "a"), .integer(5))

        let result = await store.save()

        XCTAssertEqual(result, .saved(reload: .reloaded))
        XCTAssertEqual(liveConfig(), "# raw edit\na = 5\n")
    }

    func test_store_replaceText_withIdenticalText_staysClean() throws {
        try writeConfig("a = 1\n")
        let store = makeStore()
        store.load()
        store.replaceText("a = 1\n")
        XCTAssertFalse(store.isDirty)
    }
}
