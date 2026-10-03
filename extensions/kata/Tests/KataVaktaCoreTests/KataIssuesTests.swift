//
//  KataIssuesTests.swift
//  KataVaktaCoreTests
//
//  Decoding Kata's CLI JSON and building the Issues Panel View.

import XCTest
import VaktaExtensionKit
@testable import KataVaktaCore

final class KataIssuesTests: XCTestCase {
    private let listJSON = #"""
        {"kata_api_version":1,"issues":[
          {"id":120,"uid":"01M","project_id":5,"project_uid":"01P","short_id":"b3hb","title":"Link CLI","status":"open",
           "priority":3,"author":"sam","metadata":{},"revision":1,"qualified_id":"vakta#b3hb","labels":["extensions"],
           "parent":{"uid":"01Q","short_id":"3kav","project":"vakta","qualified_id":"vakta#3kav","status":"open"},
           "body":"## What to build\nA CLI."},
          {"id":121,"project_id":5,"short_id":"1zdc","title":"Panel View","status":"open","priority":2,"owner":"sam","labels":[]}
        ]}
        """#

    func test_decodeIssues_readsTheFieldsTheViewUses() {
        XCTAssertEqual(KataOutput.decodeIssues(Data(listJSON.utf8)), .issues([
            KataIssue(
                shortID: "b3hb", projectID: 5, title: "Link CLI", status: "open", priority: 3, owner: nil,
                labels: ["extensions"], body: "## What to build\nA CLI.", parent: .init(shortID: "3kav", status: "open")
            ),
            KataIssue(shortID: "1zdc", projectID: 5, title: "Panel View", status: "open", priority: 2, owner: "sam", labels: [], body: nil, parent: nil),
        ]))
    }

    func test_decodeIssues_notInitializedAndOtherErrors() {
        let notInitialized = #"{"error":{"kind":"not_found","code":"project_not_initialized","message":"no .kata.toml ancestor and no git ancestor","exit_code":4}}"#
        XCTAssertEqual(KataOutput.decodeIssues(Data(notInitialized.utf8)), .notInitialized)

        let other = #"{"error":{"kind":"usage","message":"accepts 1 arg(s), received 0","exit_code":2}}"#
        XCTAssertEqual(KataOutput.decodeIssues(Data(other.utf8)), .failed("accepts 1 arg(s), received 0"))

        XCTAssertEqual(KataOutput.decodeIssues(Data("garbage".utf8)), .failed("kata printed something kata-vakta doesn't understand."))
    }

    private func issue(_ id: String, priority: Int? = 2, owner: String? = nil, labels: [String] = [], body: String? = nil) -> KataIssue {
        KataIssue(shortID: id, projectID: 5, title: "Title \(id)", status: "open", priority: priority, owner: owner, labels: labels, body: body, parent: nil)
    }

    private func sections(_ document: ViewDocument) -> [String: [String]] {
        guard case .list(let list) = document else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.sections.map { ($0.title ?? "", $0.items.map(\.id)) })
    }

    func test_issues_groupsClaimedReadyAndBlocked_sortedByPriorityThenID() {
        let document = KataViews.issues(
            open: [
                issue("zz01", priority: 1), issue("aa02", priority: 1), issue("cl01", owner: "sam"),
                issue("bl01", priority: 0), issue("rd03", priority: nil),
            ],
            readyIDs: ["zz01", "aa02", "cl01", "rd03"]
        )
        XCTAssertEqual(sections(document), [
            "In progress": ["cl01"],
            "Ready": ["aa02", "zz01", "rd03"],
            "Blocked": ["bl01"],
        ])
        guard case .list(let list) = document else { return XCTFail() }
        XCTAssertEqual(list.sections.map(\.title), ["In progress", "Ready", "Blocked"])
        XCTAssertEqual(list.searchPlaceholder, "Filter issues")
    }

    func test_issues_omitsEmptySections_andSaysWhenThereAreNone() {
        XCTAssertEqual(sections(KataViews.issues(open: [issue("rd01")], readyIDs: ["rd01"])), ["Ready": ["rd01"]])
        guard case .list(let empty) = KataViews.issues(open: [], readyIDs: []) else { return XCTFail() }
        XCTAssertEqual(empty.sections, [])
        XCTAssertEqual(empty.emptyText, "No open issues")
    }

    func test_issueRow_andDetail() {
        let document = KataViews.issues(
            open: [issue("cl01", priority: 1, owner: "sam", labels: ["extensions", "epic", "third"], body: "Body text")],
            readyIDs: []
        )
        guard case .list(let list) = document, let row = list.sections.first?.items.first else { return XCTFail() }
        XCTAssertEqual(row.title, "Title cl01")
        XCTAssertEqual(row.subtitle, "cl01 · P1 · @sam")
        XCTAssertEqual(row.symbol, "circle.lefthalf.filled")
        XCTAssertEqual(row.accessories.map(\.text), ["extensions", "epic"])
        XCTAssertEqual(row.buttons, [], "a claimed issue offers no Claim")
        XCTAssertEqual(row.detail, .detail(DetailView(
            title: "cl01 · Title cl01",
            markdown: "Body text",
            fields: [
                .init(label: "Priority", value: "P1"),
                .init(label: "Owner", value: "sam"),
                .init(label: "Labels", value: "extensions, epic, third"),
            ],
            buttons: KataForms.detailButtons(issue: "cl01")
        )))
    }

    func test_rowSymbols_readyAndBlocked() {
        guard case .list(let list) = KataViews.issues(open: [issue("rd01"), issue("bl01")], readyIDs: ["rd01"]) else { return XCTFail() }
        XCTAssertEqual(list.sections.map { $0.items.first?.symbol }, ["circle", "lock"])
    }

    func test_workspace_prefersTheGitRoot() {
        func context(cwd: String?, gitRoot: String?) -> ExtensionContext {
            ExtensionContext(sessionKey: SessionKey(backend: "herdr", sessionName: "v"), cwd: cwd, gitRoot: gitRoot, branch: nil, workspace: nil, focused: true)
        }
        XCTAssertEqual(KataViews.workspace(for: context(cwd: "/r/Sources", gitRoot: "/r")), "/r")
        XCTAssertEqual(KataViews.workspace(for: context(cwd: "/tmp", gitRoot: nil)), "/tmp")
        XCTAssertNil(KataViews.workspace(for: context(cwd: nil, gitRoot: nil)))
        XCTAssertNil(KataViews.workspace(for: nil))
    }

    func test_notInitialized_andNoFocus_areDetailDocuments() {
        guard case .detail(let detail) = KataViews.notInitialized(directory: "/tmp/x") else { return XCTFail() }
        XCTAssertEqual(detail.title, "No Kata project here")
        XCTAssertTrue(detail.markdown?.contains("/tmp/x") == true)
        guard case .detail = KataViews.noFocusedSession else { return XCTFail() }
    }
}

final class KataButtonsTests: XCTestCase {
    private func issue(_ id: String, owner: String? = nil) -> KataIssue {
        KataIssue(shortID: id, projectID: 5, title: id, status: "open", priority: 1, owner: owner, labels: [], body: nil, parent: nil)
    }

    private let claim = { (id: String) in
        ViewButton(title: "Claim", symbol: "hand.raised", callback: "claim", payload: .object(["id": .string(id)]),
                   style: .default, confirm: nil, shortcut: "cmd+return")
    }

    func test_unownedIssues_offerClaim_onTheRowAndInTheDetail() {
        guard case .list(let list) = KataViews.issues(open: [issue("rd01"), issue("bl01")], readyIDs: ["rd01"]) else { return XCTFail() }
        for item in list.sections.flatMap(\.items) {
            XCTAssertEqual(item.buttons, [claim(item.id)], item.id)
            guard case .detail(let detail)? = item.detail else { return XCTFail() }
            XCTAssertEqual(detail.buttons, [claim(item.id)] + KataForms.detailButtons(issue: item.id), item.id)
        }
    }

    func test_claimEffects_confirmAndRefresh() {
        XCTAssertEqual(KataCallbacks.claimed("rd01"), [.toast(text: "Claimed rd01"), .refresh])
    }

    func test_issueID_fromPayload() {
        XCTAssertEqual(KataCallbacks.issueID(.object(["id": .string("rd01")])), "rd01")
        XCTAssertNil(KataCallbacks.issueID(.object(["id": .number(3)])))
        XCTAssertNil(KataCallbacks.issueID(nil))
        XCTAssertNil(KataCallbacks.issueID(.object(["id": .string("--force")])), "an id that looks like a flag is refused")
    }
}
