//
//  GitHubPanel.swift
//  GitHubCore
//
//  The Pull Requests Panel View, the actions on a PR (as Effects or `gh`
//  argv, never shell text), and the ⌘K Commands for the focused PR. No
//  merge in v1.

import Foundation
import VaktaExtensionKit

/// What an action needs to know about a PR; travels as a button payload.
public struct PullRequestRef: Equatable, Sendable {
    public var url: String
    public var number: Int
    public var title: String
    public var repository: String
    public var branch: String
    public var cwd: String?
    public var isDraft: Bool
    public var state: PullRequestState

    public init(_ pr: PullRequest, target: PullRequestTarget, cwd: String?) {
        url = pr.url
        number = pr.number
        title = pr.title
        repository = target.repository.slug
        branch = target.branch
        self.cwd = cwd
        isDraft = pr.isDraft
        state = pr.state
    }

    public var payload: JSONValue {
        var fields: [String: JSONValue] = [
            "url": .string(url), "number": .number(Double(number)), "title": .string(title),
            "repository": .string(repository), "branch": .string(branch),
        ]
        if let cwd { fields["cwd"] = .string(cwd) }
        return .object(fields)
    }

    /// From a button payload; nil unless every field is sane (they become
    /// `gh` arguments, so nothing flag-like).
    public static func decode(_ payload: JSONValue?) -> (url: String, number: Int, title: String, repository: String, branch: String, cwd: String?)? {
        guard case .object(let fields)? = payload,
              case .string(let url)? = fields["url"], case .number(let number)? = fields["number"],
              case .string(let repository)? = fields["repository"], case .string(let branch)? = fields["branch"],
              number >= 1, number.rounded() == number,
              !repository.hasPrefix("-"), !branch.hasPrefix("-"),
              repository.split(separator: "/").count >= 2
        else { return nil }
        var title = ""
        if case .string(let given)? = fields["title"] { title = given }
        var cwd: String?
        if case .string(let given)? = fields["cwd"] { cwd = given }
        return (url, Int(number), title, repository, branch, cwd)
    }
}

public enum GitHubActions {
    public static let checkout = "checkout"
    public static let rerun = "rerun-failed"
    public static let fix = "fix-with-agent"
    public static let copy = "copy-link"
    public static let ready = "mark-ready"
    public static let draft = "convert-to-draft"

    public static func buttons(_ ref: PullRequestRef) -> [ViewButton] {
        func button(_ title: String, _ symbol: String, _ callback: String, style: ViewButton.Style = .default) -> ViewButton {
            ViewButton(title: title, symbol: symbol, callback: callback, payload: ref.payload, style: style, confirm: nil, shortcut: nil)
        }
        var buttons = [GitHubLook.openButton(ref.url), button("Check Out", "arrow.down.to.line", checkout)]
        if ref.state == .failing { buttons.append(button("Re-run Failed", "arrow.clockwise", rerun)) }
        if ref.state == .failing || ref.state == .changesRequested {
            buttons.append(button("Fix with Agent", "wand.and.stars", fix, style: .primary))
        }
        buttons.append(button("Copy Link", "link", copy))
        buttons.append(ref.isDraft ? button("Mark Ready", "checkmark.seal", ready) : button("Convert to Draft", "pencil.circle", draft))
        return buttons
    }

    /// ⌘K Commands for the focused pane's PR.
    public static func commands(_ ref: PullRequestRef?) -> [ExtensionCommand] {
        guard let ref else { return [] }
        return buttons(ref).map { button in
            let title: String
            switch button.callback {
            case GitHubCallbacks.openURL: title = "Open PR #\(ref.number)"
            case checkout: title = "Check Out PR #\(ref.number)"
            case rerun: title = "Re-run Failed Checks on #\(ref.number)"
            case fix: title = "Fix PR #\(ref.number) with Agent"
            case copy: title = "Copy Link to PR #\(ref.number)"
            case ready: title = "Mark PR #\(ref.number) Ready for Review"
            default: title = "Convert PR #\(ref.number) to Draft"
            }
            return ExtensionCommand(id: "\(button.callback)-\(ref.number)", title: title, symbol: button.symbol,
                                    callback: button.callback, payload: button.payload)
        }
    }

    public static func checkoutEffects(repository: String, number: Int, cwd: String?) -> [Effect] {
        [.openPane(cwd: cwd, command: ["gh", "pr", "checkout", String(number), "--repo", repository], title: "#\(number)")]
    }

    public static func fixPrompt(number: Int, title: String, repository: String, branch: String, state: PullRequestState?) -> String {
        if state == .changesRequested {
            return "Address the requested changes on pull request #\(number) (\(title)) in \(repository), branch \(branch). Read the review with `gh pr view \(number) --repo \(repository) --comments`."
        }
        return "Fix the failing checks on pull request #\(number) (\(title)) in \(repository), branch \(branch). See them with `gh pr checks \(number) --repo \(repository)`."
    }

    /// The agent command with `{prompt}` substituted inside its words.
    public static func agentCommand(template: [String], prompt: String) -> [String] {
        template.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }
    }

    public static func readyArgv(repository: String, number: Int, ready: Bool) -> [String] {
        ["gh", "pr", "ready", String(number), "--repo", repository] + (ready ? [] : ["--undo"])
    }

    public static func failedRunsArgv(repository: String, branch: String) -> [String] {
        ["gh", "run", "list", "--repo", repository, "--branch", branch, "--status", "failure", "--limit", "10", "--json", "databaseId"]
    }

    public static func rerunArgv(repository: String, runID: Int) -> [String] {
        ["gh", "run", "rerun", String(runID), "--failed", "--repo", repository]
    }

    /// Run ids from `gh run list --json databaseId`.
    public static func runIDs(_ data: Data) -> [Int] {
        struct Run: Decodable { var databaseId: Int }
        return ((try? JSONDecoder().decode([Run].self, from: data)) ?? []).map(\.databaseId)
    }
}

public struct GitHubConfig: Equatable, Sendable {
    public var agentCommand: [String]

    public static let `default` = GitHubConfig(agentCommand: ["claude", "{prompt}"])

    public static func decode(_ data: Data?) -> GitHubConfig {
        struct File: Decodable { var agentCommand: [String]? }
        guard let data, let command = (try? JSONDecoder().decode(File.self, from: data))?.agentCommand, !command.isEmpty else { return .default }
        return GitHubConfig(agentCommand: command)
    }
}

public enum GitHubPanel {
    public static let viewID = "pulls"

    /// PRs for branches open in any pane, by repository, focused repo first.
    public static func view(_ placements: [PullRequestPlacement], focusedRepository: String?) -> ViewDocument {
        var repositories: [String] = []
        var rows: [String: [ListItem]] = [:]
        var seen = Set<String>()
        for placement in placements {
            guard let pr = placement.pullRequest, seen.insert(pr.url).inserted else { continue }
            let repository = placement.target.repository.slug
            if rows[repository] == nil { repositories.append(repository) }
            let ref = PullRequestRef(pr, target: placement.target, cwd: placement.pane.gitRoot)
            rows[repository, default: []].append(ListItem(
                id: pr.url, title: "#\(pr.number) \(pr.title)",
                subtitle: "\(GitHubLook.describe(pr.state)) · \(placement.target.branch)\(pr.isDraft ? " · draft" : "")",
                symbol: GitHubLook.symbol(pr.state),
                accessories: pr.checks.isEmpty ? [] : [Accessory(text: "\(pr.passing)/\(pr.checks.count)", symbol: nil)],
                detail: detail(pr, ref: ref), buttons: [GitHubLook.openButton(pr.url)]
            ))
        }
        let ordered = repositories.filter { $0 == focusedRepository } + repositories.filter { $0 != focusedRepository }
        return .list(ListView(
            title: nil, searchPlaceholder: "Filter pull requests", emptyText: "No pull requests for the branches in your panes",
            sections: ordered.map { repository in
                ListSection(title: repository, items: (rows[repository] ?? []).sorted { $0.id < $1.id })
            }
        ))
    }

    static func detail(_ pr: PullRequest, ref: PullRequestRef) -> ViewDocument {
        var fields: [DetailView.Field] = [
            .init(label: "State", value: GitHubLook.describe(pr.state)),
            .init(label: "Branch", value: ref.branch),
        ]
        if let review = pr.review {
            fields.append(.init(label: "Review", value: review == .approved ? "approved" : review == .changesRequested ? "changes requested" : "review required"))
        }
        if !pr.checks.isEmpty { fields.append(.init(label: "Checks", value: "\(pr.passing)/\(pr.checks.count) passing")) }
        let checkLines = pr.orderedChecks.map { check -> String in
            let mark: String
            switch check.state {
            case .failing: mark = "✗"
            case .pending: mark = "…"
            case .passing: mark = "✓"
            }
            return "\(mark) \(check.name)"
        }
        return .detail(DetailView(
            title: "#\(pr.number) \(pr.title)", markdown: checkLines.isEmpty ? nil : checkLines.joined(separator: "\n"),
            fields: fields, buttons: GitHubActions.buttons(ref)
        ))
    }
}
