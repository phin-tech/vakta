//
//  ProtocolFixtureTests.swift
//  VaktaExtensionKitTests
//
//  Every golden fixture both ways: the fixture decodes to the expected typed
//  value, and that value encodes back to the fixture's JSON. The fixtures,
//  not these Swift types, are the contract.

import XCTest
import VaktaExtensionKit

final class ProtocolFixtureTests: XCTestCase {
    private enum Envelope {
        case request(JSONRPCID, String)
        case notification(String)
        case response(JSONRPCID)
    }

    private let vaktaSession = SessionKey(backend: "herdr", sessionName: "vakta")

    // MARK: - Host → Extension

    func test_initializeRequest() throws {
        try assertFixture("initialize.request", .request(.number(1), ProtocolMethod.initialize), InitializeParams(
            apiVersion: vaktaExtensionAPIVersion,
            host: HostInfo(name: "Vakta", version: "0.1.0"),
            capabilities: HostCapabilities(
                viewKinds: ["list", "detail", "form"],
                effects: ["refresh", "replace", "push", "pop", "toast", "notify", "open_url", "open_pane", "open_session"]
            )
        ))
    }

    func test_contextsChanged_omitsAbsentLocationFields() throws {
        try assertFixture("contexts-changed", .notification(ProtocolMethod.contextsChanged), ContextsChangedParams(contexts: [
            ExtensionContext(
                sessionKey: vaktaSession,
                cwd: "/Users/sam/src/vakta/Sources",
                gitRoot: "/Users/sam/src/vakta",
                branch: "3kav-extensions",
                workspace: WorkspaceRef(id: "w2C", label: "agents"),
                focused: true
            ),
            ExtensionContext(
                sessionKey: SessionKey(backend: "tmux", sessionName: "scratch"),
                cwd: "/tmp", gitRoot: nil, branch: nil, workspace: nil, focused: false
            ),
        ]))
    }

    func test_viewRenderRequest() throws {
        try assertFixture("view-render.request", .request(.string("r-7"), ProtocolMethod.viewRender), ViewRenderParams(view: "issues"))
    }

    func test_callbackRequest_carriesArbitraryPayloadAndFormValues() throws {
        try assertFixture("callback.request", .request(.number(12), ProtocolMethod.callback), CallbackParams(
            view: "issues",
            callback: "close-submit",
            payload: .object([
                "id": .string("fcae"), "priority": .number(2), "tags": .array([.string("a"), .string("b")]),
                "urgent": .bool(false), "parent": .null,
            ]),
            form: ["message": .string("Implemented and verified."), "notify": .bool(true)]
        ))
    }

    func test_cancel() throws {
        try assertFixture("cancel", .notification(ProtocolMethod.cancel), CancelParams(id: .string("r-7")))
    }

    func test_shutdownRequest_hasNoParams() throws {
        try assertParamless("shutdown.request", .request(id: .number(99), method: ProtocolMethod.shutdown, params: nil))
    }

    // MARK: - Extension → host

    func test_initializeResponse() throws {
        try assertFixture("initialize.response", .response(.number(1)), InitializeResult(apiVersion: 1, name: "Kata"))
    }

    func test_viewRenderResponse_listWithDetailButtonsAndConfirm() throws {
        let detail = ViewDocument.detail(DetailView(
            title: "fcae · VaktaExtensionKit protocol types",
            markdown: "## What to build\nShared types.",
            fields: [DetailView.Field(label: "Priority", value: "2")],
            buttons: []
        ))
        let claim = ViewButton(
            title: "Claim", symbol: "hand.raised", callback: "claim", payload: .object(["id": .string("fcae")]),
            style: .default, confirm: nil, shortcut: nil
        )
        let close = ViewButton(
            title: "Close…", symbol: nil, callback: "close", payload: .object(["id": .string("fcae")]),
            style: .destructive,
            confirm: ViewButton.Confirm(title: "Close fcae?", message: "This asserts the work is complete.", button: "Close"),
            shortcut: "cmd+backspace"
        )
        try assertFixture("view-render.response.list", .response(.string("r-7")), ViewDocument.list(ListView(
            title: nil,
            searchPlaceholder: "Filter issues",
            emptyText: "No open issues",
            buttons: [ViewButton(title: "New Issue…", symbol: "plus", callback: "new-form", payload: nil, style: .default, confirm: nil, shortcut: nil)],
            sections: [
                ListSection(title: "Ready", items: [
                    ListItem(
                        id: "fcae", title: "VaktaExtensionKit protocol types", subtitle: "P2 · sphinizy",
                        symbol: "circle", accessories: [Accessory(text: "extensions", symbol: nil)],
                        detail: detail, buttons: [claim, close]
                    ),
                ]),
                ListSection(title: nil, items: []),
            ]
        )))
    }

    func test_viewUpdate_detailDocument() throws {
        try assertFixture("view-update.detail", .notification(ProtocolMethod.viewUpdate), ViewUpdateParams(
            view: "issues",
            document: .detail(DetailView(
                title: "7cq8 · Link, Trust, developer mode", markdown: nil, fields: [],
                buttons: [ViewButton(
                    title: "Start", symbol: "play", callback: "start", payload: .object(["id": .string("7cq8")]),
                    style: .primary, confirm: nil, shortcut: "return"
                )]
            ))
        ))
    }

    func test_viewInvalidate() throws {
        try assertFixture("view-invalidate", .notification(ProtocolMethod.viewInvalidate), ViewInvalidateParams(view: "issues"))
    }

    func test_callbackResponse_everyEffectType() throws {
        let form = ViewDocument.form(FormView(
            title: "Close fcae",
            fields: [
                FormField(id: "message", label: "Message", required: true, kind: .multiline(placeholder: "What was done", value: nil)),
                FormField(id: "summary", label: "Summary", required: false, kind: .text(placeholder: nil, value: "done")),
                FormField(id: "reason", label: "Reason", required: true, kind: .picker(
                    options: [FormField.Option(value: "done", label: "Done"), FormField.Option(value: "wontfix", label: "Won't fix")],
                    selected: "done"
                )),
                FormField(id: "notify", label: "Notify", required: false, kind: .toggle(isOn: true)),
            ],
            submit: ViewButton(
                title: "Close", symbol: nil, callback: "close-submit", payload: .object(["id": .string("fcae")]),
                style: .primary, confirm: nil, shortcut: nil
            )
        ))
        try assertFixture("callback.response", .response(.number(12)), CallbackResult(effects: [
            .refresh,
            .replace(.list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: []))),
            .push(form),
            .pop,
            .toast(text: "Claimed fcae"),
            .notify(title: "fcae closed", body: "By sphinizy"),
            .openURL("https://github.com/phin-tech/vakta/pull/3"),
            .openPane(cwd: "/Users/sam/src/vakta", command: ["claude", "work on kata fcae"], title: "fcae"),
            .openSession(cwd: nil, command: ["kata", "tui"], title: nil),
        ]))
    }

    func test_errorResponse() throws {
        try assertParamless("error.response", .errorResponse(
            id: .number(12), error: JSONRPCError(code: -32603, message: "kata claim failed: issue already owned")
        ))
    }

    func test_statusSet_withPopoverList() throws {
        try assertFixture("status-set", .notification(ProtocolMethod.statusSet), StatusSetParams(
            text: "3 ready",
            symbol: "checklist",
            popover: .list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [
                ListSection(title: "Ready", items: [
                    ListItem(
                        id: "fcae", title: "VaktaExtensionKit protocol types", subtitle: nil, symbol: nil,
                        accessories: [], detail: nil, buttons: []
                    ),
                ]),
            ]))
        ))
    }

    func test_statusClear_hasNoParams() throws {
        try assertParamless("status-clear", .notification(method: ProtocolMethod.statusClear, params: nil))
    }

    func test_badgeSet_withoutPopover() throws {
        try assertFixture("badge-set", .notification(ProtocolMethod.badgeSet), BadgeSetParams(
            sessionKey: vaktaSession, text: "fcae", symbol: "circle.fill", popover: nil
        ))
    }

    func test_badgeClear() throws {
        try assertFixture("badge-clear", .notification(ProtocolMethod.badgeClear), BadgeClearParams(sessionKey: vaktaSession))
    }

    func test_log() throws {
        try assertFixture("log", .notification(ProtocolMethod.log), LogParams(
            level: .warning, message: "kata daemon not reachable; retrying"
        ))
    }

    // MARK: - Coverage of the fixture directory

    /// A fixture added without a test here would be a contract nobody checks.
    func test_everyFixtureHasACase() {
        let covered: Set<String> = [
            "initialize.request", "contexts-changed", "view-render.request", "callback.request", "cancel",
            "shutdown.request", "initialize.response", "view-render.response.list", "view-update.detail",
            "view-invalidate", "callback.response", "error.response", "status-set", "status-clear",
            "badge-set", "badge-clear", "log",
        ]
        XCTAssertEqual(Set(ProtocolFixture.allNames), covered)
    }

    // MARK: - Helpers

    /// Decodes the fixture's envelope and payload and compares them with
    /// `expected`, then encodes `expected` in the same envelope and compares
    /// the result with the fixture's JSON.
    private func assertFixture<Payload: Codable & Equatable>(
        _ name: String, _ envelope: Envelope, _ expected: Payload,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let fixture = try ProtocolFixture.line(name, file: file, line: line)
        let message = try ExtensionProtocolCodec.decodeLine(fixture)

        let decodedPayload: JSONValue?
        switch (envelope, message) {
        case let (.request(id, method), .request(actualID, actualMethod, params)):
            XCTAssertEqual(actualID, id, file: file, line: line)
            XCTAssertEqual(actualMethod, method, file: file, line: line)
            decodedPayload = params
        case let (.notification(method), .notification(actualMethod, params)):
            XCTAssertEqual(actualMethod, method, file: file, line: line)
            decodedPayload = params
        case let (.response(id), .response(actualID, result)):
            XCTAssertEqual(actualID, id, file: file, line: line)
            decodedPayload = result
        default:
            return XCTFail("\(name): envelope \(message) doesn't match \(envelope)", file: file, line: line)
        }
        let payload = try XCTUnwrap(decodedPayload, "\(name): no params/result", file: file, line: line)
        XCTAssertEqual(try ExtensionProtocolCodec.decode(Payload.self, from: payload), expected, file: file, line: line)

        let encodedPayload = try ExtensionProtocolCodec.encode(expected)
        let reencoded: JSONRPCMessage
        switch envelope {
        case let .request(id, method): reencoded = .request(id: id, method: method, params: encodedPayload)
        case let .notification(method): reencoded = .notification(method: method, params: encodedPayload)
        case let .response(id): reencoded = .response(id: id, result: encodedPayload)
        }
        assertSameJSON(try ExtensionProtocolCodec.encodeLine(reencoded), fixture, file: file, line: line)
    }

    /// For messages whose whole meaning is the envelope.
    private func assertParamless(
        _ name: String, _ expected: JSONRPCMessage, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let fixture = try ProtocolFixture.line(name, file: file, line: line)
        XCTAssertEqual(try ExtensionProtocolCodec.decodeLine(fixture), expected, file: file, line: line)
        assertSameJSON(try ExtensionProtocolCodec.encodeLine(expected), fixture, file: file, line: line)
    }
}
