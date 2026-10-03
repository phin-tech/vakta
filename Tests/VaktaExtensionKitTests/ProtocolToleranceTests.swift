//
//  ProtocolToleranceTests.swift
//  VaktaExtensionKitTests
//
//  How payloads from a newer or sloppier peer decode: unknown fields are
//  ignored, unknown document kinds, form field kinds and Effect types become
//  explicit `.unsupported` values without failing their neighbours, and
//  collections an author leaves out mean "empty".

import XCTest
import VaktaExtensionKit

final class ProtocolToleranceTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try ExtensionProtocolCodec.decode(type, from: jsonValue(json))
    }

    // MARK: - Unknown fields

    func test_unknownFields_areIgnored() throws {
        XCTAssertEqual(
            try decode(ExtensionContext.self, #"{"sessionKey":{"backend":"zellij","sessionName":"z","pid":4},"focused":false,"agent":"claude"}"#),
            ExtensionContext(
                sessionKey: SessionKey(backend: "zellij", sessionName: "z"),
                cwd: nil, gitRoot: nil, branch: nil, workspace: nil, focused: false
            )
        )
        XCTAssertEqual(
            try decode(Effect.self, #"{"type":"toast","text":"Saved","durationMs":900}"#),
            .toast(text: "Saved")
        )
    }

    // MARK: - Unknown kinds and types

    func test_unknownDocumentKind_isUnsupported_insideAnOtherwiseValidList() throws {
        let list = try decode(ViewDocument.self, #"""
            {"kind":"list","sections":[{"items":[{"id":"a","title":"A","detail":{"kind":"chart","series":[1,2]}}]}]}
            """#)

        guard case .list(let view) = list else { return XCTFail("expected a list, got \(list)") }
        XCTAssertEqual(view.sections.first?.items.first?.detail, .unsupported(kind: "chart"))
    }

    func test_unknownEffectType_isUnsupported_andLaterEffectsStillDecode() throws {
        XCTAssertEqual(
            try decode(CallbackResult.self, #"{"effects":[{"type":"confetti","amount":3},{"type":"refresh"}]}"#),
            CallbackResult(effects: [.unsupported(type: "confetti"), .refresh])
        )
    }

    func test_unknownFormFieldKind_isUnsupported_butKeepsIdentity() throws {
        XCTAssertEqual(
            try decode(FormField.self, #"{"id":"due","label":"Due","kind":"date","value":"2026-10-03"}"#),
            FormField(id: "due", label: "Due", required: false, kind: .unsupported(kind: "date"))
        )
    }

    func test_buttonStyle_unknownOrMissing_isDefault() throws {
        for json in [#"{"title":"Go","callback":"go","style":"glowing"}"#, #"{"title":"Go","callback":"go"}"#] {
            XCTAssertEqual(
                try decode(ViewButton.self, json),
                ViewButton(title: "Go", symbol: nil, callback: "go", payload: nil, style: .default, confirm: nil, shortcut: nil),
                json
            )
        }
    }

    // MARK: - Omitted collections

    func test_omittedCollections_decodeAsEmpty() throws {
        XCTAssertEqual(
            try decode(ViewDocument.self, #"{"kind":"list"}"#),
            .list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: []))
        )
        XCTAssertEqual(try decode(ListSection.self, #"{"title":"Ready"}"#), ListSection(title: "Ready", items: []))
        XCTAssertEqual(
            try decode(ListItem.self, #"{"id":"a","title":"A"}"#),
            ListItem(id: "a", title: "A", subtitle: nil, symbol: nil, accessories: [], detail: nil, buttons: [])
        )
        XCTAssertEqual(
            try decode(ViewDocument.self, #"{"kind":"detail","title":"A"}"#),
            .detail(DetailView(title: "A", markdown: nil, fields: [], buttons: []))
        )
        XCTAssertEqual(
            try decode(FormField.self, #"{"id":"p","label":"Pick","kind":"picker"}"#),
            FormField(id: "p", label: "Pick", required: false, kind: .picker(options: [], selected: nil))
        )
        XCTAssertEqual(
            try decode(FormField.self, #"{"id":"t","label":"On","kind":"toggle"}"#),
            FormField(id: "t", label: "On", required: false, kind: .toggle(isOn: false))
        )
    }

    // MARK: - Shape errors

    func test_documentWithoutKind_orEffectWithoutType_isPayloadMismatch() {
        let cases: [(String, () throws -> Any)] = [
            ("document", { try self.decode(ViewDocument.self, #"{"title":"A"}"#) }),
            ("effect", { try self.decode(Effect.self, #"{"text":"Saved"}"#) }),
            ("openPane without command", { try self.decode(Effect.self, #"{"type":"open_pane","cwd":"/tmp"}"#) }),
        ]
        for (label, decodeIt) in cases {
            XCTAssertThrowsError(try decodeIt(), label) { error in
                guard case .payloadMismatch? = error as? ExtensionProtocolError else {
                    return XCTFail("\(label): expected payloadMismatch, got \(error)")
                }
            }
        }
    }
}
