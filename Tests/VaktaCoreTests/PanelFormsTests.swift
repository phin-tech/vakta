//
//  PanelFormsTests.swift
//  VaktaCoreTests
//
//  Form View Documents: seeded values, edits, required fields (whitespace
//  doesn't count), unsupported field kinds, and the submitted values.

import XCTest
import VaktaExtensionKit
@testable import Vakta

final class PanelFormsTests: XCTestCase {
    private let submit = ViewButton(title: "Close", symbol: nil, callback: "close-submit", payload: nil, style: .primary, confirm: nil, shortcut: nil)

    private func form(_ fields: [FormField]) -> FormView {
        FormView(title: "Close", fields: fields, submit: submit)
    }

    private let closeForm: [FormField] = [
        FormField(id: "message", label: "Message", required: true, kind: .multiline(placeholder: nil, value: nil)),
        FormField(id: "commit", label: "Commit", required: false, kind: .text(placeholder: "sha", value: "abc123")),
        FormField(id: "reason", label: "Reason", required: true, kind: .picker(
            options: [.init(value: "done", label: "Done"), .init(value: "wontfix", label: "Won't fix")], selected: "done")),
        FormField(id: "notify", label: "Notify", required: false, kind: .toggle(isOn: true)),
    ]

    func test_valuesAreSeededFromTheDocument() {
        let state = FormState(form: form(closeForm))
        XCTAssertEqual(state.text("message"), "")
        XCTAssertEqual(state.text("commit"), "abc123")
        XCTAssertEqual(state.choice("reason"), "done")
        XCTAssertTrue(state.isOn("notify"))
    }

    func test_requiredEmptyFields_blockSubmit_andProblemsShowAfterTheAttempt() {
        var state = FormState(form: form(closeForm))
        XCTAssertEqual(state.problems, ["message": "Required"])
        XCTAssertFalse(state.attemptedSubmit)

        XCTAssertNil(state.submit())
        XCTAssertTrue(state.attemptedSubmit)

        state.setText("message", "   \n ")
        XCTAssertNil(state.submit(), "whitespace doesn't satisfy a required field")
    }

    func test_submit_sendsEveryFieldsValue() {
        var state = FormState(form: form(closeForm))
        state.setText("message", "Implemented and verified.")
        state.setChoice("reason", "wontfix")
        state.setToggle("notify", false)

        XCTAssertEqual(state.submit(), [
            "message": .string("Implemented and verified."),
            "commit": .string("abc123"),
            "reason": .string("wontfix"),
            "notify": .bool(false),
        ])
    }

    func test_requiredPickerWithoutSelection_isAProblem() {
        var state = FormState(form: form([
            FormField(id: "priority", label: "Priority", required: true, kind: .picker(options: [.init(value: "1", label: "P1")], selected: nil)),
        ]))
        XCTAssertEqual(state.problems, ["priority": "Required"])
        state.setChoice("priority", "1")
        XCTAssertEqual(state.submit(), ["priority": .string("1")])
    }

    func test_optionalEmptyPicker_andText_areOmittedOrEmpty() {
        var state = FormState(form: form([
            FormField(id: "label", label: "Label", required: false, kind: .picker(options: [], selected: nil)),
            FormField(id: "note", label: "Note", required: false, kind: .text(placeholder: nil, value: nil)),
        ]))
        XCTAssertEqual(state.submit(), ["note": .string("")], "an unselected optional picker sends nothing")
    }

    func test_unsupportedFields_areSkipped_unlessRequired() {
        var optional = FormState(form: form([
            FormField(id: "due", label: "Due", required: false, kind: .unsupported(kind: "date")),
        ]))
        XCTAssertEqual(optional.submit(), [:])

        var required = FormState(form: form([
            FormField(id: "due", label: "Due", required: true, kind: .unsupported(kind: "date")),
        ]))
        XCTAssertEqual(required.problems, ["due": "Needs a newer Vakta"])
        XCTAssertNil(required.submit())
    }

    func test_editsToUnknownFields_areIgnored() {
        var state = FormState(form: form(closeForm))
        state.setText("nope", "x")
        state.setToggle("message", true)
        XCTAssertEqual(state.text("nope"), "")
        XCTAssertEqual(state.text("message"), "", "a toggle edit can't turn a text field into a bool")
    }
}
