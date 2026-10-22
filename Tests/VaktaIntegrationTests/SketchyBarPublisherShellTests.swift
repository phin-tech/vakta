//
//  SketchyBarPublisherShellTests.swift
//  VaktaIntegrationTests
//
//  Shell cases for `SketchyBarPublisher` against a stateful fake
//  `sketchybar`: a script that keeps one file per item and behaves like the
//  real CLI where it matters (a repeated `--add` succeeds, `--set` on a
//  missing item exits 1, `--remove` deletes). Assertions read the fake's
//  items, not its invocations.

import XCTest
@testable import Vakta

@MainActor
final class SketchyBarPublisherShellTests: XCTestCase {
    private var tempDirectory: URL!
    private var itemsDirectory: URL!
    private var executableURL: URL!
    private var now = Date(timeIntervalSinceReferenceDate: 10_000)

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarPublisherShellTests-\(UUID().uuidString)", isDirectory: true)
        itemsDirectory = tempDirectory.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)

        executableURL = tempDirectory.appendingPathComponent("sketchybar")
        try writeFakeSketchyBar()
    }

    private func writeFakeSketchyBar() throws {
        let script = """
        #!/bin/sh
        dir='\(itemsDirectory.path)'
        while [ $# -gt 0 ]; do
            case "$1" in
                --add)
                    [ "$2" = item ] || exit 2
                    [ -f "$dir/$3" ] || : > "$dir/$3"
                    shift 4 ;;
                --set)
                    name="$2"; shift 2
                    [ -f "$dir/$name" ] || { echo "[!] Set: Item not found '$name'" >&2; exit 1; }
                    while [ $# -gt 0 ]; do
                        case "$1" in --*) break ;; esac
                        key="${1%%=*}"
                        grep -v "^$key=" "$dir/$name" > "$dir/$name.tmp"
                        printf '%s\\n' "$1" >> "$dir/$name.tmp"
                        mv "$dir/$name.tmp" "$dir/$name"
                        shift
                    done ;;
                --remove)
                    [ -f "$dir/$2" ] || exit 1
                    rm "$dir/$2"; shift 2 ;;
                *) exit 2 ;;
            esac
        done
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makePublisher() -> SketchyBarPublisher {
        SketchyBarPublisher(executable: executableURL.path, now: { [unowned self] in self.now })
    }

    private var itemURL: URL { itemsDirectory.appendingPathComponent(SketchyBarCommand.itemName) }

    /// The fake item's properties, or nil when the bar has no `vakta` item.
    private func itemProperties() -> [String: String]? {
        guard let text = try? String(contentsOf: itemURL, encoding: .utf8) else { return nil }
        var properties: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            properties[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return properties
    }

    func test_enabled_drawsTheItemWithCountsColourAndClickScript() async {
        let outcome = await makePublisher().update(enabled: true, statuses: [.attention, .done, .working, .working])

        XCTAssertEqual(outcome, .published)
        let properties = itemProperties()
        XCTAssertEqual(properties?["label"], "!1 ✓1 2")
        XCTAssertEqual(properties?["label.drawing"], "on")
        XCTAssertEqual(properties?["icon.color"], SketchyBarItemPlanner.attentionColor)
        XCTAssertEqual(properties?["click_script"], "open -g vakta://menu")
    }

    func test_statusChange_updatesTheItemInPlace() async {
        let publisher = makePublisher()
        _ = await publisher.update(enabled: true, statuses: [.working])
        _ = await publisher.update(enabled: true, statuses: [.idle])

        XCTAssertEqual(itemProperties()?["label.drawing"], "off")
        XCTAssertEqual(itemProperties()?["icon.color"], SketchyBarItemPlanner.idleColor)
    }

    func test_turnedOff_removesTheItem() async {
        let publisher = makePublisher()
        _ = await publisher.update(enabled: true, statuses: [.working])
        let outcome = await publisher.update(enabled: false, statuses: [.working])

        XCTAssertEqual(outcome, .removed)
        XCTAssertNil(itemProperties())
    }

    func test_offFromLaunch_leavesTheBarAlone() async {
        let outcome = await makePublisher().update(enabled: false, statuses: [.working])

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertNil(itemProperties())
    }

    func test_itemDroppedByAReload_comesBackAfterTheReassertInterval() async throws {
        let publisher = makePublisher()
        _ = await publisher.update(enabled: true, statuses: [.working])
        try FileManager.default.removeItem(at: itemURL)  // `sketchybar --reload`

        now = now.addingTimeInterval(SketchyBarSyncPlanner.reassertInterval)
        let outcome = await publisher.update(enabled: true, statuses: [.working])

        XCTAssertEqual(outcome, .published)
        XCTAssertEqual(itemProperties()?["label"], "1")
    }

    func test_failedCommand_isReported_andRetriedOnTheNextUpdate() async throws {
        // A bar that rejects everything (SketchyBar not running).
        try "#!/bin/sh\nexit 1\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let publisher = makePublisher()

        let failed = await publisher.update(enabled: true, statuses: [.working])
        XCTAssertEqual(failed, .failed(.nonZeroExit(1)))

        try writeFakeSketchyBar()  // SketchyBar is back
        let retried = await publisher.update(enabled: true, statuses: [.working])
        XCTAssertEqual(retried, .published)
        XCTAssertEqual(itemProperties()?["label"], "1")
    }

    func test_noExecutable_isUnavailable() async {
        let outcome = await SketchyBarPublisher(executable: nil).update(enabled: true, statuses: [.working])

        XCTAssertEqual(outcome, .unavailable)
    }
}
