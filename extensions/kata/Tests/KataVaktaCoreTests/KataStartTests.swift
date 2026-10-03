//
//  KataStartTests.swift
//  KataVaktaCoreTests

import XCTest
import VaktaExtensionKit
@testable import KataVaktaCore

final class KataStartTests: XCTestCase {
    func test_config_defaultsToClaudeWithThePrompt() {
        XCTAssertEqual(KataConfig.decode(nil), .default)
        XCTAssertEqual(KataConfig.decode(Data("garbage".utf8)), .default)
        XCTAssertEqual(KataConfig.decode(Data(#"{"agentCommand": []}"#.utf8)), .default)
        XCTAssertEqual(
            KataConfig.decode(Data(#"{"agentCommand": ["codex", "--yolo", "{prompt}"]}"#.utf8)),
            KataConfig(agentCommand: ["codex", "--yolo", "{prompt}"])
        )
    }

    func test_prompt_namesTheIssueAndHowToReadIt() {
        XCTAssertEqual(
            KataStart.prompt(id: "fcae", title: "Protocol kit"),
            "Work on Kata issue fcae: Protocol kit. Read it first with `kata show fcae`."
        )
    }

    func test_command_substitutesPlaceholdersInsideWords_withoutSplittingThem() {
        XCTAssertEqual(
            KataStart.command(template: ["claude", "{prompt}"], id: "fcae", title: "Fix $(it); now"),
            ["claude", "Work on Kata issue fcae: Fix $(it); now. Read it first with `kata show fcae`."]
        )
        XCTAssertEqual(
            KataStart.command(template: ["agent", "--issue={id}", "--name", "{title}"], id: "fcae", title: "Kit"),
            ["agent", "--issue=fcae", "--name", "Kit"]
        )
    }

    func test_effects_openAPaneInTheRepo_thenConfirm() {
        XCTAssertEqual(
            KataStart.effects(id: "fcae", workspace: "/repo", command: ["claude", "go"]),
            [.openPane(cwd: "/repo", command: ["claude", "go"], title: "fcae"), .toast(text: "Started fcae"), .refresh]
        )
    }

    func test_sessionMap_recordsAndLooksUpBySessionKey_andRoundTrips() throws {
        var map = KataSessionMap()
        let vakta = SessionKey(backend: "herdr", sessionName: "vakta")
        map.record("fcae", for: vakta)
        map.record("7cq8", for: SessionKey(backend: "tmux", sessionName: "vakta"))
        map.record("hkkb", for: vakta)

        XCTAssertEqual(map.issue(for: vakta), "hkkb")
        XCTAssertEqual(map.issue(for: SessionKey(backend: "tmux", sessionName: "vakta")), "7cq8")
        XCTAssertNil(map.issue(for: SessionKey(backend: "herdr", sessionName: "other")))
        XCTAssertEqual(KataSessionMap.key(vakta), "herdr:vakta")

        let data = try JSONEncoder().encode(map)
        XCTAssertEqual(KataSessionMap.decode(data), map)
        XCTAssertEqual(KataSessionMap.decode(nil), KataSessionMap())
        XCTAssertEqual(KataSessionMap.decode(Data("junk".utf8)), KataSessionMap())
    }

    func test_startButton_andWhereItAppears() {
        XCTAssertEqual(KataStart.button(id: "fcae", title: "Kit"), ViewButton(
            title: "Start", symbol: "play.fill", callback: "start",
            payload: .object(["id": .string("fcae"), "title": .string("Kit")]),
            style: .primary, confirm: nil, shortcut: "cmd+shift+return"
        ))
        let ready = KataIssue(shortID: "rd01", projectID: 5, title: "Ready one", status: "open", priority: 1, owner: nil, labels: [], body: nil, parent: nil)
        let blocked = KataIssue(shortID: "bl01", projectID: 5, title: "Blocked one", status: "open", priority: 1, owner: nil, labels: [], body: nil, parent: nil)
        let mine = KataIssue(shortID: "cl01", projectID: 5, title: "Mine", status: "open", priority: 1, owner: "sam", labels: [], body: nil, parent: nil)
        guard case .list(let list) = KataViews.issues(open: [ready, blocked, mine], readyIDs: ["rd01"]) else { return XCTFail() }
        let items = Dictionary(uniqueKeysWithValues: list.sections.flatMap(\.items).map { ($0.id, $0) })
        XCTAssertEqual(items["rd01"]?.buttons.map(\.callback), ["start", "claim"])
        XCTAssertEqual(items["bl01"]?.buttons.map(\.callback), ["claim"], "blocked work can be claimed but not started")
        XCTAssertEqual(items["cl01"]?.buttons.map(\.callback), ["start"])
        guard case .detail(let detail)? = items["rd01"]?.detail else { return XCTFail() }
        XCTAssertEqual(detail.buttons.map(\.callback), ["start", "claim", "comment-form", "close-form"])
    }
}
