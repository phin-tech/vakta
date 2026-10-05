//
//  KataForms.swift
//  KataVaktaCore
//
//  The Comment, Close and New Issue forms, and the `kata` argv each
//  submission becomes. Values arrive as form JSON from Vakta; they are
//  passed to kata as separate arguments, never through a shell.

import Foundation
import VaktaExtensionKit

public enum KataForms {
    public static let commentForm = "comment-form"
    public static let commentSubmit = "comment-submit"
    public static let closeForm = "close-form"
    public static let closeSubmit = "close-submit"
    public static let newForm = "new-form"
    public static let newSubmit = "new-submit"

    public static func comment(issue: String) -> ViewDocument {
        .form(FormView(
            title: "Comment on \(issue)",
            fields: [FormField(id: "body", label: "Comment", required: true, kind: .multiline(placeholder: nil, value: nil))],
            submit: submit("Comment", commentSubmit, issue: issue, style: .primary)
        ))
    }

    public static func close(issue: String) -> ViewDocument {
        .form(FormView(
            title: "Close \(issue)",
            fields: [
                FormField(id: "reason", label: "Reason", required: true, kind: .picker(
                    options: [.init(value: "done", label: "Done"), .init(value: "wontfix", label: "Won't fix")], selected: "done")),
                FormField(id: "message", label: "What was done and how it was verified", required: true,
                          kind: .multiline(placeholder: nil, value: nil)),
                FormField(id: "commit", label: "Commit", required: false, kind: .text(placeholder: "sha", value: nil)),
                FormField(id: "pr", label: "Pull request", required: false, kind: .text(placeholder: "https://…", value: nil)),
                FormField(id: "test", label: "Test command", required: false, kind: .text(placeholder: "swift test", value: nil)),
            ],
            submit: submit("Close Issue", closeSubmit, issue: issue, style: .destructive)
        ))
    }

    public static func newIssue() -> ViewDocument {
        .form(FormView(
            title: "New Issue",
            fields: [
                FormField(id: "title", label: "Title", required: true, kind: .text(placeholder: nil, value: nil)),
                FormField(id: "body", label: "Description", required: false, kind: .multiline(placeholder: nil, value: nil)),
                FormField(id: "priority", label: "Priority", required: false, kind: .picker(
                    options: (0...4).map { .init(value: String($0), label: "P\($0)") }, selected: "2")),
            ],
            submit: ViewButton(title: "Create", symbol: nil, callback: newSubmit, payload: nil, style: .primary, confirm: nil, shortcut: "cmd+return")
        ))
    }

    /// `kata` arguments for a submitted form, or what's missing. The
    /// workspace and `--json` are added by the caller.
    public static func arguments(for callback: String, issue: String?, values: [String: JSONValue]) -> Result<[String], KataFormError> {
        func text(_ key: String) -> String {
            if case .string(let value)? = values[key] { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
            return ""
        }
        switch callback {
        case commentSubmit:
            guard let issue else { return .failure(.missing("issue")) }
            let body = text("body")
            guard !body.isEmpty else { return .failure(.missing("body")) }
            return .success(["comment", issue, "--body", body])
        case closeSubmit:
            guard let issue else { return .failure(.missing("issue")) }
            let reason = text("reason")
            guard ["done", "wontfix"].contains(reason) else { return .failure(.missing("reason")) }
            let message = text("message")
            guard !message.isEmpty else { return .failure(.missing("message")) }
            var arguments = ["close", issue, "--reason", reason, "--message", message]
            for (key, flag) in [("commit", "--commit"), ("pr", "--pr"), ("test", "--test")] where !text(key).isEmpty {
                arguments += [flag, text(key)]
            }
            return .success(arguments)
        case newSubmit:
            let title = text("title")
            guard !title.isEmpty else { return .failure(.missing("title")) }
            var flags: [String] = []
            if !text("body").isEmpty { flags += ["--body", text("body")] }
            if let priority = Int(text("priority")), (0...4).contains(priority) { flags += ["--priority", String(priority)] }
            // A title starting with "-" goes after `--` (flags must precede it)
            // so kata reads it as the title, not a flag.
            return .success(title.hasPrefix("-") ? ["create"] + flags + ["--", title] : ["create", title] + flags)
        default:
            return .failure(.unknownForm)
        }
    }

    /// Effects after a successful submission.
    public static func effects(after callback: String, created: String?) -> [Effect] {
        switch callback {
        case commentSubmit: return [.pop, .toast(text: "Comment added"), .refresh]
        // Pop the form and the closed issue's detail.
        case closeSubmit: return [.pop, .pop, .toast(text: "Closed"), .refresh]
        case newSubmit: return [.pop, .toast(text: created.map { "Created \($0)" } ?? "Created"), .refresh]
        default: return [.refresh]
        }
    }

    /// The short id in `kata create --json` output.
    public static func createdID(_ data: Data) -> String? {
        struct Issue: Decodable { var short_id: String }
        struct Wrapped: Decodable { var issue: Issue }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: data) { return wrapped.issue.short_id }
        return (try? JSONDecoder().decode(Issue.self, from: data))?.short_id
    }

    static func headerButtons() -> [ViewButton] {
        [ViewButton(title: "New Issue…", symbol: "plus", callback: newForm, payload: nil, style: .default, confirm: nil, shortcut: nil)]
    }

    static func detailButtons(issue: String) -> [ViewButton] {
        [
            ViewButton(title: "Comment…", symbol: "text.bubble", callback: commentForm, payload: .object(["id": .string(issue)]),
                       style: .default, confirm: nil, shortcut: nil),
            ViewButton(title: "Close…", symbol: "checkmark.circle", callback: closeForm, payload: .object(["id": .string(issue)]),
                       style: .default, confirm: nil, shortcut: nil),
        ]
    }

    private static func submit(_ title: String, _ callback: String, issue: String, style: ViewButton.Style) -> ViewButton {
        ViewButton(title: title, symbol: nil, callback: callback, payload: .object(["id": .string(issue)]),
                   style: style, confirm: nil, shortcut: "cmd+return")
    }
}

public enum KataFormError: Error, Equatable {
    case unknownForm
    case missing(String)
}
