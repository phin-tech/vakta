//
//  KataIssues.swift
//  KataVaktaCore
//
//  Kata's CLI JSON (`kata list --json`, `kata ready --json`, error
//  envelopes) and the Issues Panel View built from it.

import Foundation
import VaktaExtensionKit

public struct KataIssue: Decodable, Equatable {
    public struct Parent: Decodable, Equatable {
        public var shortID: String
        public var status: String?

        private enum CodingKeys: String, CodingKey {
            case shortID = "short_id"
            case status
        }

        public init(shortID: String, status: String?) {
            self.shortID = shortID
            self.status = status
        }
    }

    public var shortID: String
    public var projectID: Int?
    public var title: String
    public var status: String
    public var priority: Int?
    public var owner: String?
    public var labels: [String]
    public var body: String?
    public var parent: Parent?

    public init(
        shortID: String, projectID: Int?, title: String, status: String, priority: Int?, owner: String?,
        labels: [String], body: String?, parent: Parent?
    ) {
        self.shortID = shortID
        self.projectID = projectID
        self.title = title
        self.status = status
        self.priority = priority
        self.owner = owner
        self.labels = labels
        self.body = body
        self.parent = parent
    }

    private enum CodingKeys: String, CodingKey {
        case shortID = "short_id"
        case projectID = "project_id"
        case title, status, priority, owner, labels, body, parent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            shortID: try container.decode(String.self, forKey: .shortID),
            projectID: try container.decodeIfPresent(Int.self, forKey: .projectID),
            title: try container.decode(String.self, forKey: .title),
            status: try container.decode(String.self, forKey: .status),
            priority: try container.decodeIfPresent(Int.self, forKey: .priority),
            owner: try container.decodeIfPresent(String.self, forKey: .owner),
            labels: try container.decodeIfPresent([String].self, forKey: .labels) ?? [],
            body: try container.decodeIfPresent(String.self, forKey: .body),
            parent: try container.decodeIfPresent(Parent.self, forKey: .parent)
        )
    }
}

/// What a `kata` invocation produced, decoded from its stdout.
public enum KataOutput: Equatable {
    case issues([KataIssue])
    /// No `.kata.toml` (or git) ancestor: `kata init` is needed.
    case notInitialized
    case failed(String)

    public static func decodeIssues(_ data: Data) -> KataOutput {
        struct List: Decodable { var issues: [KataIssue] }
        struct Failure: Decodable {
            struct Body: Decodable {
                var code: String?
                var message: String
            }
            var error: Body
        }
        if let list = try? JSONDecoder().decode(List.self, from: data) {
            return .issues(list.issues)
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            return failure.error.code == "project_not_initialized" ? .notInitialized : .failed(failure.error.message)
        }
        return .failed("kata printed something kata-vakta doesn't understand.")
    }
}

public enum KataViews {
    public static let issuesViewID = "issues"

    /// The Issues view for one project: In progress (claimed), Ready, Blocked.
    public static func issues(open: [KataIssue], readyIDs: Set<String>) -> ViewDocument {
        let sorted = open.sorted { ($0.priority ?? Int.max, $0.shortID) < ($1.priority ?? Int.max, $1.shortID) }
        let claimed = sorted.filter { $0.owner != nil }
        let ready = sorted.filter { $0.owner == nil && readyIDs.contains($0.shortID) }
        let blocked = sorted.filter { $0.owner == nil && !readyIDs.contains($0.shortID) }
        let sections = [
            ("In progress", claimed, "circle.lefthalf.filled", true),
            ("Ready", ready, "circle", true),
            ("Blocked", blocked, "lock", false),
        ].compactMap { title, issues, symbol, startable -> ListSection? in
            issues.isEmpty ? nil : ListSection(title: title, items: issues.map { row($0, symbol: symbol, startable: startable) })
        }
        return .list(ListView(
            title: nil, searchPlaceholder: "Filter issues", emptyText: "No open issues",
            buttons: KataForms.headerButtons(), sections: sections
        ))
    }

    /// The Status Item: how many issues are ready to start (unowned, no open
    /// blockers), with a Popover whose rows start them. `nil` when none.
    public static func status(open: [KataIssue], readyIDs: Set<String>) -> StatusSetParams? {
        let ready = open
            .filter { $0.owner == nil && readyIDs.contains($0.shortID) }
            .sorted { ($0.priority ?? Int.max, $0.shortID) < ($1.priority ?? Int.max, $1.shortID) }
        guard !ready.isEmpty else { return nil }
        let rows = ready.map { row($0, symbol: "circle", startable: true) }
        return StatusSetParams(
            text: "\(ready.count) ready",
            symbol: "checklist",
            popover: .list(ListView(title: nil, searchPlaceholder: nil, emptyText: nil, sections: [ListSection(title: "Ready", items: rows)]))
        )
    }

    public static func notInitialized(directory: String) -> ViewDocument {
        .detail(DetailView(
            title: "No Kata project here",
            markdown: "\(directory) isn't part of a Kata project. Run `kata init` there to track issues.",
            fields: [], buttons: []
        ))
    }

    public static let noFocusedSession = ViewDocument.detail(DetailView(
        title: "No session", markdown: "Focus a session in a repository to see its issues.", fields: [], buttons: []
    ))

    /// Where `kata` should resolve the project for a Session.
    public static func workspace(for context: ExtensionContext?) -> String? {
        context?.gitRoot ?? context?.cwd
    }

    private static func row(_ issue: KataIssue, symbol: String, startable: Bool) -> ListItem {
        let subtitle = [issue.shortID, issue.priority.map { "P\($0)" }, issue.owner.map { "@\($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return ListItem(
            id: issue.shortID,
            title: issue.title,
            subtitle: subtitle,
            symbol: symbol,
            accessories: issue.labels.prefix(2).map { Accessory(text: $0, symbol: nil) },
            detail: detail(issue, startable: startable),
            buttons: buttons(for: issue, startable: startable)
        )
    }

    private static func detail(_ issue: KataIssue, startable: Bool) -> ViewDocument {
        var fields: [DetailView.Field] = []
        if let priority = issue.priority { fields.append(.init(label: "Priority", value: "P\(priority)")) }
        if let owner = issue.owner { fields.append(.init(label: "Owner", value: owner)) }
        if !issue.labels.isEmpty { fields.append(.init(label: "Labels", value: issue.labels.joined(separator: ", "))) }
        if let parent = issue.parent { fields.append(.init(label: "Parent", value: parent.shortID)) }
        return .detail(DetailView(
            title: "\(issue.shortID) · \(issue.title)", markdown: issue.body, fields: fields,
            buttons: buttons(for: issue, startable: startable) + KataForms.detailButtons(issue: issue.shortID)
        ))
    }

    /// Start for work that can begin (claimed or ready); Claim while unowned.
    private static func buttons(for issue: KataIssue, startable: Bool) -> [ViewButton] {
        (startable ? [KataStart.button(id: issue.shortID, title: issue.title)] : [])
            + (issue.owner == nil ? [KataCallbacks.claimButton(issue.shortID)] : [])
    }
}

public enum KataCallbacks {
    public static let claim = "claim"

    public static func claimed(_ id: String) -> [Effect] {
        [.toast(text: "Claimed \(id)"), .refresh]
    }

    /// The issue id in a button payload, if it's a plausible Kata ref (it is
    /// passed to `kata` as an argument, so never something flag-like).
    public static func issueID(_ payload: JSONValue?) -> String? {
        guard case .object(let fields)? = payload, case .string(let id)? = fields["id"],
              !id.isEmpty, !id.hasPrefix("-"),
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "#" || $0 == "-" || $0 == "_" })
        else { return nil }
        return id
    }

    static func claimButton(_ id: String) -> ViewButton {
        ViewButton(
            title: "Claim", symbol: "hand.raised", callback: claim, payload: .object(["id": .string(id)]),
            style: .default, confirm: nil, shortcut: "cmd+return"
        )
    }
}
