//
//  PanelForms.swift
//  Vakta
//
//  Pure state for a form View Document: values seeded from the document,
//  edits, required-field validation, and the values sent with the submit
//  Callback (field id → string or bool).

import Foundation
import VaktaExtensionKit

struct FormState: Equatable {
    enum Value: Equatable {
        case text(String)
        case toggle(Bool)
        case choice(String?)
    }

    let form: FormView
    private(set) var values: [String: Value] = [:]
    /// Set by a submit attempt; problems show only after one.
    private(set) var attemptedSubmit = false

    init(form: FormView) {
        self.form = form
        for field in form.fields {
            switch field.kind {
            case let .text(_, value), let .multiline(_, value): values[field.id] = .text(value ?? "")
            case let .picker(_, selected): values[field.id] = .choice(selected)
            case .toggle(let isOn): values[field.id] = .toggle(isOn)
            case .unsupported: break
            }
        }
    }

    func text(_ id: String) -> String {
        if case .text(let text)? = values[id] { return text }
        return ""
    }

    func isOn(_ id: String) -> Bool {
        if case .toggle(let isOn)? = values[id] { return isOn }
        return false
    }

    func choice(_ id: String) -> String? {
        if case .choice(let value)? = values[id] { return value }
        return nil
    }

    mutating func setText(_ id: String, _ text: String) {
        guard case .text? = values[id] else { return }
        values[id] = .text(text)
    }

    mutating func setToggle(_ id: String, _ isOn: Bool) {
        guard case .toggle? = values[id] else { return }
        values[id] = .toggle(isOn)
    }

    mutating func setChoice(_ id: String, _ value: String?) {
        guard case .choice? = values[id] else { return }
        values[id] = .choice(value)
    }

    /// Field id → problem, for fields that block submitting.
    var problems: [String: String] {
        var found: [String: String] = [:]
        for field in form.fields where field.required {
            switch field.kind {
            case .unsupported:
                found[field.id] = "Needs a newer Vakta"
            case .text, .multiline:
                if text(field.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found[field.id] = "Required" }
            case .picker:
                if choice(field.id) == nil { found[field.id] = "Required" }
            case .toggle:
                break
            }
        }
        return found
    }

    /// Marks a submit attempt; returns the values to send, or `nil` while
    /// there are problems.
    mutating func submit() -> [String: JSONValue]? {
        attemptedSubmit = true
        guard problems.isEmpty else { return nil }
        var submission: [String: JSONValue] = [:]
        for (id, value) in values {
            switch value {
            case .text(let text): submission[id] = .string(text)
            case .toggle(let isOn): submission[id] = .bool(isOn)
            case .choice(let choice?): submission[id] = .string(choice)
            case .choice(nil): break
            }
        }
        return submission
    }
}
