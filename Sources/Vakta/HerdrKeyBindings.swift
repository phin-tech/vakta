//
//  HerdrKeyBindings.swift
//  Vakta
//
//  Pure model for editing herdr's `[keys]` table: the chord grammar herdr
//  accepts (`prefix+shift+n`, `cmd+1..9`, `ctrl+alt+]`), the catalog of
//  bindable actions with their documented defaults, conflict detection, and
//  per-row state/input rules. Herdr's grammar differs from Vakta's own
//  keybindings (`prefix+` sequences, `1..9` ranges, named punctuation), so it
//  has its own parser rather than reusing `Keybinding`. Advisory only --
//  `herdr config check` remains the arbiter.

import Foundation

struct HerdrKeyChord: Equatable {
    enum Modifier: String, CaseIterable {
        case ctrl, alt, shift, cmd, `super`
    }

    let usesPrefix: Bool
    let modifiers: Set<Modifier>
    let key: String

    /// Canonical spelling: prefix, then modifiers in a fixed order, then key.
    var formatted: String {
        var parts: [String] = usesPrefix ? ["prefix"] : []
        parts += Modifier.allCases.filter(modifiers.contains).map(\.rawValue)
        parts.append(key)
        return parts.joined(separator: "+")
    }

    var isRange: Bool { key.contains("..") }

    private static let namedKeys: Set<String> = [
        "enter", "tab", "esc", "left", "right", "up", "down", "space", "backspace", "delete", "home", "end",
        "pageup", "pagedown", "insert", "minus", "comma", "ampersand", "plus", "backtick", "period", "slash",
        "backslash", "semicolon", "quote", "equals"
    ]

    static func parse(_ text: String) -> Result<HerdrKeyChord, HerdrConfigInputError> {
        func fail(_ message: String) -> Result<HerdrKeyChord, HerdrConfigInputError> {
            .failure(HerdrConfigInputError(message: message))
        }
        let tokens = text.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 1, !tokens.contains(where: \.isEmpty) else { return fail("Incomplete key binding.") }

        var remaining = tokens[...]
        var usesPrefix = false
        if remaining.first == "prefix" {
            usesPrefix = true
            remaining = remaining.dropFirst()
        }
        guard let key = remaining.last else { return fail("Missing key after prefix.") }
        var modifiers = Set<Modifier>()
        for token in remaining.dropLast() {
            guard let modifier = Modifier(rawValue: token) else {
                return fail(token == "prefix" ? "“prefix” must come first." : "Unknown modifier “\(token)”.")
            }
            guard modifiers.insert(modifier).inserted else { return fail("Duplicate modifier “\(token)”.") }
        }
        guard isValidKey(key) else { return fail("Unknown key “\(key)”.") }
        return .success(HerdrKeyChord(usesPrefix: usesPrefix, modifiers: modifiers, key: key))
    }

    private static func isValidKey(_ key: String) -> Bool {
        if Modifier(rawValue: key) != nil || key == "prefix" { return false }
        if namedKeys.contains(key) { return true }
        if key.count == 1 { return key.first.map { !$0.isWhitespace } ?? false }
        if key.count == 4, key.dropFirst(1).hasPrefix(".."), key.first?.isNumber == true, key.last?.isNumber == true {
            return true
        }
        if key.hasPrefix("f"), let number = Int(key.dropFirst()) { return (1...24).contains(number) }
        return false
    }
}

enum HerdrKeyGroup: CaseIterable {
    case general, workspaces, tabs, panes, resize, agents, navigate

    var title: String {
        switch self {
        case .general: return "General"
        case .workspaces: return "Workspaces & Worktrees"
        case .tabs: return "Tabs"
        case .panes: return "Panes"
        case .resize: return "Resize"
        case .agents: return "Agents"
        case .navigate: return "Navigate mode"
        }
    }
}

struct HerdrKeyAction: Equatable {
    let name: String
    let label: String
    /// nil when herdr leaves the action unbound by default.
    let defaultBinding: String?
    let group: HerdrKeyGroup

    var path: String { "keys.\(name)" }
}

enum HerdrKeyActionCatalog {
    static func action(named name: String) -> HerdrKeyAction? { byName[name] }

    static func actions(in group: HerdrKeyGroup) -> [HerdrKeyAction] { actions.filter { $0.group == group } }

    private static let byName = Dictionary(uniqueKeysWithValues: actions.map { ($0.name, $0) })

    private static func make(_ name: String, _ label: String, _ binding: String?, _ group: HerdrKeyGroup) -> HerdrKeyAction {
        HerdrKeyAction(name: name, label: label, defaultBinding: binding, group: group)
    }

    // Source: herdr.dev/docs/config-reference and `herdr --default-config`.
    static let actions: [HerdrKeyAction] = [
        make("prefix", "Prefix key", "ctrl+b", .general),
        make("help", "Help", "prefix+?", .general),
        make("settings", "Settings", "prefix+s", .general),
        make("detach", "Detach", "prefix+q", .general),
        make("reload_config", "Reload config", "prefix+shift+r", .general),
        make("open_notification_target", "Open notification target", "prefix+o", .general),
        make("goto", "Go to", "prefix+g", .general),
        make("edit_scrollback", "Edit scrollback", "prefix+e", .general),
        make("copy_mode", "Copy mode", "prefix+[", .general),
        make("toggle_sidebar", "Toggle sidebar", "prefix+b", .general),
        make("remote_image_paste", "Remote image paste", "ctrl+v", .general),

        make("workspace_picker", "Workspace picker", "prefix+w", .workspaces),
        make("new_workspace", "New workspace", "prefix+shift+n", .workspaces),
        make("rename_workspace", "Rename workspace", "prefix+shift+w", .workspaces),
        make("close_workspace", "Close workspace", "prefix+shift+d", .workspaces),
        make("previous_workspace", "Previous workspace", nil, .workspaces),
        make("next_workspace", "Next workspace", nil, .workspaces),
        make("switch_workspace", "Switch to workspace 1–9", nil, .workspaces),
        make("new_worktree", "New worktree", "prefix+shift+g", .workspaces),
        make("open_worktree", "Open worktree", nil, .workspaces),
        make("remove_worktree", "Remove worktree", nil, .workspaces),

        make("new_tab", "New tab", "prefix+c", .tabs),
        make("rename_tab", "Rename tab", "prefix+shift+t", .tabs),
        make("previous_tab", "Previous tab", "prefix+p", .tabs),
        make("next_tab", "Next tab", "prefix+n", .tabs),
        make("move_tab_previous", "Move tab toward front", nil, .tabs),
        make("move_tab_next", "Move tab toward back", nil, .tabs),
        make("switch_tab", "Switch to tab 1–9", "prefix+1..9", .tabs),
        make("close_tab", "Close tab", "prefix+shift+x", .tabs),

        make("focus_pane_left", "Focus pane left", "prefix+h", .panes),
        make("focus_pane_down", "Focus pane down", "prefix+j", .panes),
        make("focus_pane_up", "Focus pane up", "prefix+k", .panes),
        make("focus_pane_right", "Focus pane right", "prefix+l", .panes),
        make("swap_pane_left", "Swap pane left", "prefix+shift+h", .panes),
        make("swap_pane_down", "Swap pane down", "prefix+shift+j", .panes),
        make("swap_pane_up", "Swap pane up", "prefix+shift+k", .panes),
        make("swap_pane_right", "Swap pane right", "prefix+shift+l", .panes),
        make("cycle_pane_next", "Next pane", "prefix+tab", .panes),
        make("cycle_pane_previous", "Previous pane", "prefix+shift+tab", .panes),
        make("last_pane", "Last pane", nil, .panes),
        make("rename_pane", "Rename pane", "prefix+shift+p", .panes),
        make("split_vertical", "Split vertically", "prefix+v", .panes),
        make("split_horizontal", "Split horizontally", "prefix+minus", .panes),
        make("close_pane", "Close pane", "prefix+x", .panes),
        make("zoom", "Zoom pane", "prefix+z", .panes),

        make("resize_mode", "Resize mode", "prefix+r", .resize),
        make("resize_pane_left", "Resize pane left", nil, .resize),
        make("resize_pane_down", "Resize pane down", nil, .resize),
        make("resize_pane_up", "Resize pane up", nil, .resize),
        make("resize_pane_right", "Resize pane right", nil, .resize),

        make("previous_agent", "Previous agent", nil, .agents),
        make("next_agent", "Next agent", nil, .agents),
        make("focus_agent", "Focus agent 1–9", nil, .agents),

        make("navigate_workspace_up", "Workspace up", "up", .navigate),
        make("navigate_workspace_down", "Workspace down", "down", .navigate),
        make("navigate_pane_left", "Pane left", "h", .navigate),
        make("navigate_pane_down", "Pane down", "j", .navigate),
        make("navigate_pane_up", "Pane up", "k", .navigate),
        make("navigate_pane_right", "Pane right", "l", .navigate)
    ]
}

enum HerdrKeyBindingRules {
    /// Nil when `binding` is acceptable for `action`; otherwise a short reason.
    static func problem(for binding: String, action: HerdrKeyAction) -> String? {
        if binding.trimmingCharacters(in: .whitespaces).isEmpty {
            return action.defaultBinding == nil
                ? nil
                : "Can't be empty — use reset to restore herdr's default."
        }
        let chord: HerdrKeyChord
        switch HerdrKeyChord.parse(binding) {
        case .failure(let error): return error.message
        case .success(let parsed): chord = parsed
        }
        if action.name == "prefix", chord.usesPrefix { return "The prefix key can't itself use “prefix+”." }
        if action.group == .navigate {
            if chord.usesPrefix { return "Navigate-mode keys can't use “prefix+”." }
            if ["esc", "enter", "tab"].contains(chord.key) || chord.isRange {
                return "Navigate-mode keys can't be esc, enter, tab, or 1..9."
            }
        }
        return nil
    }
}

enum HerdrKeyConflicts {
    /// Canonical chord -> the action names sharing it (only where 2+ do),
    /// in the order given. Empty and unparseable bindings are ignored.
    static func find(in bindings: [(String, String)]) -> [String: [String]] {
        var groups: [String: [String]] = [:]
        for (name, binding) in bindings {
            guard case .success(let chord) = HerdrKeyChord.parse(binding) else { continue }
            groups[chord.formatted, default: []].append(name)
        }
        return groups.filter { $0.value.count > 1 }
    }

    /// Effective bindings across the whole catalog (file value, else default).
    static func find(in document: HerdrConfigDocument) -> [String: [String]] {
        find(in: HerdrKeyActionCatalog.actions.compactMap { action in
            let state = HerdrKeyBindingState.resolve(action, in: document)
            return state.binding.isEmpty ? nil : (action.name, state.binding)
        })
    }
}

struct HerdrKeyBindingState: Equatable {
    /// The file's binding if it is a plain string, else the default ("" if none).
    let binding: String
    let isSetInFile: Bool
    /// False for values the editor doesn't own (e.g. `next_tab = ["a", "b"]`).
    let isEditable: Bool
    let rawText: String?
    let problem: String?

    static func resolve(_ action: HerdrKeyAction, in document: HerdrConfigDocument) -> HerdrKeyBindingState {
        guard let value = document.value(at: action.path) else {
            return HerdrKeyBindingState(
                binding: action.defaultBinding ?? "", isSetInFile: false, isEditable: true, rawText: nil, problem: nil)
        }
        guard case .string(let text) = value else {
            return HerdrKeyBindingState(
                binding: "", isSetInFile: true, isEditable: false, rawText: value.sourceText, problem: nil)
        }
        return HerdrKeyBindingState(
            binding: text, isSetInFile: true, isEditable: true, rawText: value.sourceText,
            problem: HerdrKeyBindingRules.problem(for: text, action: action))
    }
}

enum HerdrKeyBindingInput {
    /// Keeps the user's own spelling (trimmed) rather than rewriting to the
    /// canonical form, so a hand-tuned file isn't churned.
    static func value(from input: String, for action: HerdrKeyAction) -> Result<HerdrConfigValue, HerdrConfigInputError> {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if let problem = HerdrKeyBindingRules.problem(for: trimmed, action: action) {
            return .failure(HerdrConfigInputError(message: problem))
        }
        return .success(.string(trimmed))
    }
}
