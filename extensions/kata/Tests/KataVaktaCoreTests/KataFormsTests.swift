//
//  KataFormsTests.swift
//  KataVaktaCoreTests

import XCTest
import VaktaExtensionKit
@testable import KataVaktaCore

final class KataFormsTests: XCTestCase {
    private func form(_ document: ViewDocument) -> FormView? {
        if case .form(let form) = document { return form }
        return nil
    }

    func test_commentForm_hasARequiredBody_andSubmitsForTheIssue() throws {
        let comment = try XCTUnwrap(form(KataForms.comment(issue: "fcae")))
        XCTAssertEqual(comment.title, "Comment on fcae")
        XCTAssertEqual(comment.fields.map(\.id), ["body"])
        XCTAssertEqual(comment.fields.first?.required, true)
        XCTAssertEqual(comment.submit.callback, KataForms.commentSubmit)
        XCTAssertEqual(comment.submit.payload, .object(["id": .string("fcae")]))
    }

    func test_closeForm_fields() throws {
        let close = try XCTUnwrap(form(KataForms.close(issue: "fcae")))
        XCTAssertEqual(close.fields.map(\.id), ["reason", "message", "commit", "pr", "test"])
        XCTAssertEqual(close.fields.filter(\.required).map(\.id), ["reason", "message"])
        guard case .picker(let options, let selected) = close.fields[0].kind else { return XCTFail() }
        XCTAssertEqual(options.map(\.value), ["done", "wontfix"])
        XCTAssertEqual(selected, "done")
        XCTAssertEqual(close.submit.style, .destructive)
    }

    func test_newIssueForm_fields() throws {
        let new = try XCTUnwrap(form(KataForms.newIssue()))
        XCTAssertEqual(new.fields.map(\.id), ["title", "body", "priority"])
        XCTAssertEqual(new.fields.filter(\.required).map(\.id), ["title"])
        guard case .picker(let options, let selected) = new.fields[2].kind else { return XCTFail() }
        XCTAssertEqual(options.map(\.value), ["0", "1", "2", "3", "4"])
        XCTAssertEqual(selected, "2")
    }

    func test_arguments_comment() {
        XCTAssertEqual(
            KataForms.arguments(for: KataForms.commentSubmit, issue: "fcae", values: ["body": .string("Looks good; see ``x``")]),
            .success(["comment", "fcae", "--body", "Looks good; see ``x``"])
        )
        XCTAssertEqual(KataForms.arguments(for: KataForms.commentSubmit, issue: "fcae", values: ["body": .string("  ")]), .failure(.missing("body")))
        XCTAssertEqual(KataForms.arguments(for: KataForms.commentSubmit, issue: nil, values: ["body": .string("x")]), .failure(.missing("issue")))
    }

    func test_arguments_close_withEvidence() {
        XCTAssertEqual(
            KataForms.arguments(for: KataForms.closeSubmit, issue: "fcae", values: [
                "reason": .string("done"), "message": .string("Shipped and verified."),
                "commit": .string("abc123"), "pr": .string(""), "test": .string("swift test"),
            ]),
            .success(["close", "fcae", "--reason", "done", "--message", "Shipped and verified.", "--commit", "abc123", "--test", "swift test"])
        )
        XCTAssertEqual(
            KataForms.arguments(for: KataForms.closeSubmit, issue: "fcae", values: ["reason": .string("wontfix"), "message": .string("Not needed.")]),
            .success(["close", "fcae", "--reason", "wontfix", "--message", "Not needed."])
        )
        XCTAssertEqual(
            KataForms.arguments(for: KataForms.closeSubmit, issue: "fcae", values: ["reason": .string("explode"), "message": .string("x")]),
            .failure(.missing("reason"))
        )
    }

    func test_arguments_newIssue() {
        XCTAssertEqual(
            KataForms.arguments(for: KataForms.newSubmit, issue: nil, values: [
                "title": .string("Fix the thing"), "body": .string("Details"), "priority": .string("1"),
            ]),
            .success(["create", "Fix the thing", "--body", "Details", "--priority", "1"])
        )
        XCTAssertEqual(
            KataForms.arguments(for: KataForms.newSubmit, issue: nil, values: ["title": .string("Bare"), "body": .string(""), "priority": .string("9")]),
            .success(["create", "Bare"]), "an out-of-range priority is left to kata's default"
        )
        XCTAssertEqual(
            KataForms.arguments(for: KataForms.newSubmit, issue: nil, values: ["title": .string("--help")]),
            .success(["create", "--", "--help"]), "a flag-looking title stays a title"
        )
    }

    func test_effectsAfterSubmit() {
        XCTAssertEqual(KataForms.effects(after: KataForms.commentSubmit, created: nil), [.pop, .toast(text: "Comment added"), .refresh])
        XCTAssertEqual(KataForms.effects(after: KataForms.closeSubmit, created: nil), [.pop, .pop, .toast(text: "Closed"), .refresh])
        XCTAssertEqual(KataForms.effects(after: KataForms.newSubmit, created: "q9t2"), [.pop, .toast(text: "Created q9t2"), .refresh])
        XCTAssertEqual(KataForms.effects(after: KataForms.newSubmit, created: nil), [.pop, .toast(text: "Created"), .refresh])
    }

    func test_createdID() {
        XCTAssertEqual(KataForms.createdID(Data(#"{"kata_api_version":1,"issue":{"short_id":"q9t2"}}"#.utf8)), "q9t2")
        XCTAssertEqual(KataForms.createdID(Data(#"{"short_id":"q9t2"}"#.utf8)), "q9t2")
        XCTAssertNil(KataForms.createdID(Data("nope".utf8)))
    }

    func test_buttons() {
        XCTAssertEqual(KataForms.headerButtons().map(\.callback), [KataForms.newForm])
        XCTAssertEqual(KataForms.detailButtons(issue: "fcae").map(\.callback), [KataForms.commentForm, KataForms.closeForm])
        XCTAssertEqual(KataForms.detailButtons(issue: "fcae").map(\.payload), [.object(["id": .string("fcae")]), .object(["id": .string("fcae")])])
    }

    func test_issuesView_carriesTheFormButtons() {
        let issue = KataIssue(shortID: "rd01", projectID: 5, title: "t", status: "open", priority: 1, owner: nil, labels: [], body: nil, parent: nil)
        guard case .list(let list) = KataViews.issues(open: [issue], readyIDs: ["rd01"]) else { return XCTFail() }
        XCTAssertEqual(list.buttons.map(\.callback), [KataForms.newForm])
        guard case .detail(let detail)? = list.sections.first?.items.first?.detail else { return XCTFail() }
        XCTAssertEqual(detail.buttons.map(\.callback), [KataStart.callback, KataCallbacks.claim, KataForms.commentForm, KataForms.closeForm])
    }
}
