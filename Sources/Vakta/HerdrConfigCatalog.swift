//
//  HerdrConfigCatalog.swift
//  Vakta
//
//  Pure field layer for the herdr config editor: the typed catalog of scalar
//  keys the GUI edits (hand-authored from herdr.dev/docs/config-reference --
//  the basis of truth), per-field validation, text-input parsing, effective
//  value resolution against a document, and user-facing save messages.
//  Structured values (sidebar rows, custom commands, theme color layers) are
//  not in the catalog; they stay editable in the Raw tab.
//  `herdr config check` remains the arbiter; validation here is advisory.

import Foundation

enum HerdrConfigGroup: CaseIterable {
    case terminal, layout, panes, tabs, input, notifications, sound
    case session, updates, appearance, themeColors, themeLight, themeDark
    case server, worktrees, advanced, experimental

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .layout: return "Layout & Sidebar"
        case .panes: return "Panes"
        case .tabs: return "Tabs & Window"
        case .input: return "Mouse & Input"
        case .notifications: return "Notifications"
        case .sound: return "Sound"
        case .session: return "Session"
        case .updates: return "Updates"
        case .appearance: return "Theme & Accent"
        case .themeColors: return "Custom theme colors"
        case .themeLight: return "Custom colors — light appearance"
        case .themeDark: return "Custom colors — dark appearance"
        case .server: return "Server"
        case .worktrees: return "Worktrees & Remote"
        case .advanced: return "Advanced"
        case .experimental: return "Experimental"
        }
    }
}

enum HerdrConfigCatalog {
    enum Kind: Equatable {
        case bool
        case integer(ClosedRange<Int>)
        case choice([String])
        case text
        case color
    }

    struct Entry: Equatable {
        let path: String
        let kind: Kind
        let defaultValue: HerdrConfigValue
        let group: HerdrConfigGroup
        let label: String
        let help: String
        /// Only for keys herdr's docs explicitly say need a restart.
        var requiresRestart = false
    }

    static func entry(for path: String) -> Entry? { byPath[path] }

    static var groups: [HerdrConfigGroup] {
        HerdrConfigGroup.allCases.filter { !entries(in: $0).isEmpty }
    }

    static func entries(in group: HerdrConfigGroup) -> [Entry] {
        entries.filter { $0.group == group }
    }

    private static let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

    private static func flag(_ path: String, _ label: String, _ on: Bool, _ group: HerdrConfigGroup,
                             _ help: String, restart: Bool = false) -> Entry {
        Entry(path: path, kind: .bool, defaultValue: .bool(on), group: group, label: label, help: help,
              requiresRestart: restart)
    }

    private static func number(_ path: String, _ label: String, _ value: Int, _ range: ClosedRange<Int>,
                               _ group: HerdrConfigGroup, _ help: String) -> Entry {
        Entry(path: path, kind: .integer(range), defaultValue: .integer(value), group: group, label: label, help: help)
    }

    private static func choice(_ path: String, _ label: String, _ value: String, _ options: [String],
                               _ group: HerdrConfigGroup, _ help: String) -> Entry {
        Entry(path: path, kind: .choice(options), defaultValue: .string(value), group: group, label: label, help: help)
    }

    private static func text(_ path: String, _ label: String, _ value: String,
                             _ group: HerdrConfigGroup, _ help: String) -> Entry {
        Entry(path: path, kind: .text, defaultValue: .string(value), group: group, label: label, help: help)
    }

    private static func color(_ path: String, _ label: String, _ value: String,
                              _ group: HerdrConfigGroup, _ help: String) -> Entry {
        Entry(path: path, kind: .color, defaultValue: .string(value), group: group, label: label, help: help)
    }

    private static let corners = ["top-left", "top-right", "bottom-left", "bottom-right"]

    static let entries: [Entry] = [
        // Terminal
        text("terminal.default_shell", "Default shell", "", .terminal,
             "Executable for new panes. Empty uses $SHELL, then /bin/sh."),
        choice("terminal.shell_mode", "Shell mode", "auto", ["auto", "login", "non_login"], .terminal,
               "Startup mode for new pane shells."),
        text("terminal.new_cwd", "New pane directory", "follow", .terminal,
             "follow, home, current, or a fixed path such as ~/Projects."),
        flag("terminal.kitty_graphics", "Kitty graphics", true, .terminal, "Render pane images in Kitty-compatible terminals."),

        // Layout & sidebar
        number("ui.sidebar_width", "Sidebar width", 26, 1...500, .layout, "Default width in columns."),
        number("ui.sidebar_min_width", "Sidebar minimum width", 18, 1...500, .layout, "Minimum expanded width."),
        number("ui.sidebar_max_width", "Sidebar maximum width", 36, 1...500, .layout, "Maximum expanded width."),
        flag("ui.sidebar_start_collapsed", "Start collapsed", false, .layout,
             "Start with the sidebar collapsed. Takes effect on the next launch.", restart: true),
        choice("ui.sidebar_collapsed_mode", "Collapsed mode", "compact", ["compact", "hidden"], .layout,
               "compact keeps a narrow status rail; hidden uses zero width."),
        number("ui.mobile_width_threshold", "Mobile layout threshold", 64, 1...1000, .layout,
               "Terminal width at or below which the single-column layout is used."),
        choice("ui.agent_panel_sort", "Agent panel sort", "spaces", ["spaces", "priority", "workspaces"], .layout,
               "Group agents by space, or by attention priority."),
        number("ui.sidebar.agents.row_gap", "Agent row gap", 0, 0...10, .layout, "Blank rows between agent entries."),
        number("ui.sidebar.spaces.row_gap", "Space row gap", 0, 0...10, .layout, "Blank rows between space entries."),
        choice("ui.status_indicators", "Status indicators", "dots", ["dots", "symbols"], .layout,
               "Compact color dots, or distinct glyphs per state."),

        // Panes
        choice("ui.pane_borders", "Pane borders", "auto", ["auto", "always", "off"], .panes,
               "auto draws borders only for split panes."),
        flag("ui.pane_outer_borders", "Outer borders", true, .panes, "Draw borders along the outside edge."),
        flag("ui.pane_scrollbars", "Scrollbars", true, .panes, "Draw interactive scrollbars beside panes."),
        flag("ui.pane_gaps", "Pane gaps", true, .panes, "Keep split panes visually separated."),
        flag("ui.show_agent_labels_on_pane_borders", "Agent labels on borders", false, .panes,
             "Show detected agent labels when no manual pane name is set."),
        flag("ui.confirm_close", "Confirm close", true, .panes, "Ask before closing a workspace."),

        // Tabs & window
        choice("ui.tab_bar_position", "Tab bar position", "top", ["top", "bottom"], .tabs, "Where the tab row is placed."),
        flag("ui.hide_tab_bar_when_single_tab", "Hide tab bar for a single tab", false, .tabs,
             "Hide the tab row when a workspace has exactly one tab."),
        flag("ui.prompt_new_tab_name", "Prompt for new tab name", true, .tabs, "Ask for a name before creating a tab."),
        flag("ui.prompt_new_workspace_name", "Prompt for new workspace name", false, .tabs,
             "Ask for a name before creating a workspace."),
        text("ui.window_title", "Window title", "{hostname}: {workspace}", .tabs,
             "Tokens: {hostname}, {workspace}, {tab}, {pane}, {terminal_title}. Empty leaves the terminal title alone."),

        // Mouse & input
        flag("ui.mouse_capture", "Capture mouse", true, .input, "Set false to let the terminal handle normal clicks."),
        flag("ui.copy_on_select", "Copy on select", true, .input, "Copy text selected with the mouse."),
        choice("ui.host_cursor", "Host cursor", "auto", ["auto", "native", "drawn"], .input, "Cursor rendering policy."),
        text("ui.right_click_passthrough_modifier", "Right-click passthrough modifier", "", .input,
             "Modifier (ctrl, alt, cmd, super, meta, hyper) that forwards right-click to pane apps. Empty disables."),
        number("ui.mouse_scroll_lines", "Scroll lines per notch", 3, 1...1000, .input, "Lines scrolled per wheel notch."),
        flag("ui.redraw_on_focus_gained", "Redraw on focus", true, .input,
             "Force a full redraw when the outer terminal regains focus."),

        // Notifications
        choice("ui.toast.delivery", "Toast delivery", "off", ["off", "herdr", "terminal", "system"], .notifications,
               "How background notifications are shown."),
        number("ui.toast.delay_seconds", "Toast delay (seconds)", 1, 0...3600, .notifications, "0 shows immediately."),
        choice("ui.toast.herdr.position", "In-app toast position", "bottom-right", corners, .notifications,
               "Only for herdr delivery."),
        flag("ui.toast.clipboard.enabled", "Clipboard toast", true, .notifications, "Show a popup when text is copied."),
        choice("ui.toast.clipboard.position", "Clipboard toast position", "bottom-center",
               corners + ["top-center", "bottom-center"], .notifications, "Where the clipboard popup appears."),

        // Sound
        flag("ui.sound.enabled", "Play sounds", true, .sound, "Play sounds when agents change state in the background."),

        // Session
        flag("session.resume_agents_on_restore", "Resume agents on restore", true, .session,
             "Resume supported agent panes into their native conversations after a server restart."),

        // Updates
        choice("update.channel", "Update channel", "stable", ["stable", "preview"], .updates,
               "Channel used by version checks and `herdr update`."),
        flag("update.version_check", "Check for new versions", true, .updates, "Background version checks."),
        flag("update.manifest_check", "Check agent-detection manifest", true, .updates,
             "Background agent-detection manifest updates."),

        // Theme & accent
        text("theme.name", "Theme", "catppuccin", .appearance,
             "Built-in: catppuccin, terminal, tokyo-night, dracula, nord, gruvbox, one-dark, solarized, kanagawa, rose-pine, vesper."),
        flag("theme.auto_switch", "Follow terminal light/dark", false, .appearance,
             "Switch themes with the host terminal's appearance (uses light/dark theme names)."),
        text("theme.dark_name", "Dark theme", "", .appearance,
             "Theme used when auto-switch follows a dark terminal. Empty leaves it unset."),
        text("theme.light_name", "Light theme", "", .appearance,
             "Theme used when auto-switch follows a light terminal. Empty leaves it unset."),
        color("ui.accent", "Accent color", "cyan", .appearance, "Hex (#89b4fa), a color name, or rgb(r,g,b)."),

        // Server
        number("server.headless_cols", "Headless columns", 120, 1...10_000, .server,
               "Virtual terminal width when no client is attached."),
        number("server.headless_rows", "Headless rows", 40, 1...10_000, .server,
               "Virtual terminal height when no client is attached."),

        // Worktrees & remote
        text("worktrees.directory", "Worktree directory", "~/.herdr/worktrees", .worktrees,
             "Root for Git worktree checkouts."),
        flag("remote.manage_ssh_config", "Manage SSH config", true, .worktrees,
             "Use herdr's generated ssh config (keepalive, connection reuse) for --remote."),

        // Advanced
        number("advanced.scrollback_limit_bytes", "Scrollback limit (bytes)", 10_000_000, 1...2_000_000_000, .advanced,
               "Maximum scrollback buffer per pane."),

        // Experimental
        flag("experimental.allow_nested", "Allow nested herdr", false, .experimental,
             "Allow launching herdr inside an existing herdr pane."),
        flag("experimental.pane_history", "Persist pane history", false, .experimental,
             "Save recent pane screen history across server restarts."),
        flag("experimental.switch_ascii_input_source_in_prefix", "ASCII input in prefix mode", false, .experimental,
             "macOS/Windows: switch to an ASCII input source while in prefix mode."),
        flag("experimental.reveal_hidden_cursor_for_cjk_ime", "Reveal cursor for CJK IME", false, .experimental,
             "Expose the cursor anchor so input methods keep tracking the candidate window.")
    ] + themeColorEntries

    private static let themeTokens = [
        "accent", "panel_bg", "sidebar_bg", "active_row_bg", "selection_bg", "surface0", "surface1", "surface_dim",
        "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"
    ]

    /// `theme.custom.*` overrides (and the light/dark layers applied after
    /// them). All optional: unset by default, empty input means "remove".
    private static var themeColorEntries: [Entry] {
        [("theme.custom", HerdrConfigGroup.themeColors),
         ("theme.custom.light", .themeLight),
         ("theme.custom.dark", .themeDark)].flatMap { prefix, group in
            themeTokens.map { token in
                color("\(prefix).\(token)", token.replacingOccurrences(of: "_", with: " ").capitalized, "", group,
                      "Hex, color name, rgb(r,g,b), or reset. Empty removes the override.")
            }
        }
    }
}

// MARK: - Validation

enum HerdrConfigFieldValidator {
    /// Nil when `value` is acceptable for `entry`; otherwise a short reason.
    static func validate(_ value: HerdrConfigValue, for entry: HerdrConfigCatalog.Entry) -> String? {
        switch (entry.kind, value) {
        case (.bool, .bool):
            return nil
        case (.integer(let range), .integer(let number)):
            return range.contains(number) ? nil : "Must be between \(range.lowerBound) and \(range.upperBound)."
        case (.choice(let options), .string(let text)):
            return options.contains(text) ? nil : "Must be one of: \(options.joined(separator: ", "))."
        case (.text, .string):
            return nil
        case (.color, .string(let text)):
            // Optional colors (default "") treat empty as "no override".
            if text.isEmpty, entry.defaultValue == .string("") { return nil }
            return isColor(text) ? nil : "Use #RGB, #RRGGBB, rgb(r,g,b), or a color name."
        default:
            return "Expected \(expectation(for: entry.kind))."
        }
    }

    private static func expectation(for kind: HerdrConfigCatalog.Kind) -> String {
        switch kind {
        case .bool: return "true or false"
        case .integer: return "a whole number"
        case .choice, .text, .color: return "a string"
        }
    }

    private static func isColor(_ text: String) -> Bool {
        if text.hasPrefix("#") {
            let digits = text.dropFirst()
            return [3, 6].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
        }
        if text.hasPrefix("rgb("), text.hasSuffix(")") {
            let parts = text.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            return parts.count == 3 && parts.allSatisfy {
                guard let channel = Int($0.trimmingCharacters(in: .whitespaces)) else { return false }
                return (0...255).contains(channel)
            }
        }
        guard let first = text.first, first.isLetter else { return false }
        return text.allSatisfy { $0.isLetter || $0 == "_" || $0 == "-" }
    }
}

// MARK: - Text input

struct HerdrConfigInputError: Error, Equatable {
    let message: String
}

enum HerdrConfigInput {
    /// Converts what the user typed for `entry` into a validated value.
    static func value(
        from input: String, for entry: HerdrConfigCatalog.Entry
    ) -> Result<HerdrConfigValue, HerdrConfigInputError> {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let candidate: HerdrConfigValue
        switch entry.kind {
        case .bool:
            switch trimmed.lowercased() {
            case "true": candidate = .bool(true)
            case "false": candidate = .bool(false)
            default: return .failure(HerdrConfigInputError(message: "Expected true or false."))
            }
        case .integer:
            guard let number = Int(trimmed) else {
                return .failure(HerdrConfigInputError(message: "Expected a whole number."))
            }
            candidate = .integer(number)
        case .choice, .color:
            candidate = .string(trimmed)
        case .text:
            candidate = .string(input)
        }
        if let problem = HerdrConfigFieldValidator.validate(candidate, for: entry) {
            return .failure(HerdrConfigInputError(message: problem))
        }
        return .success(candidate)
    }
}

// MARK: - Field state

struct HerdrConfigFieldState: Equatable {
    /// The file's value if present, else the default.
    let value: HerdrConfigValue
    let isSetInFile: Bool
    /// False when the file holds a value of the wrong shape (or a structured
    /// value); the GUI shows `rawText` read-only rather than overwrite it.
    let isEditable: Bool
    let rawText: String?
    let problem: String?

    static func resolve(_ entry: HerdrConfigCatalog.Entry, in document: HerdrConfigDocument) -> HerdrConfigFieldState {
        guard let fileValue = document.value(at: entry.path) else {
            return HerdrConfigFieldState(
                value: entry.defaultValue, isSetInFile: false, isEditable: true, rawText: nil, problem: nil)
        }
        let problem = HerdrConfigFieldValidator.validate(fileValue, for: entry)
        return HerdrConfigFieldState(
            value: fileValue,
            isSetInFile: true,
            isEditable: hasExpectedShape(fileValue, for: entry.kind),
            rawText: fileValue.sourceText,
            problem: problem
        )
    }

    private static func hasExpectedShape(_ value: HerdrConfigValue, for kind: HerdrConfigCatalog.Kind) -> Bool {
        switch (kind, value) {
        case (.bool, .bool), (.integer, .integer), (.choice, .string), (.text, .string), (.color, .string): return true
        default: return false
        }
    }
}

// MARK: - Save messaging

struct HerdrConfigSaveMessage: Equatable {
    let text: String
    let isError: Bool

    static func describe(_ result: HerdrConfigStoreSaveResult) -> HerdrConfigSaveMessage {
        switch result {
        case .saved(reload: .reloaded):
            return HerdrConfigSaveMessage(text: "Saved and reloaded herdr.", isError: false)
        case .saved(reload: .failed(let reason)):
            return HerdrConfigSaveMessage(
                text: "Saved config.toml, but herdr did not reload it: \(reason)", isError: false)
        case .rejectedInvalid(let diagnostics):
            let detail = diagnostics.first.map { diagnostic in
                diagnostic.line > 0
                    ? " at line \(diagnostic.line), column \(diagnostic.column): \(diagnostic.message)"
                    : ": \(diagnostic.message)"
            } ?? ""
            return HerdrConfigSaveMessage(text: "herdr rejected this config\(detail). Nothing was saved.", isError: true)
        case .conflictExternalEdit:
            return HerdrConfigSaveMessage(
                text: "config.toml changed on disk since it was loaded. Nothing was saved; reload to see the changes.",
                isError: true)
        case .needsUnverifiedConfirmation:
            return HerdrConfigSaveMessage(
                text: "herdr could not be run to validate this config. Nothing was saved; save anyway to write it unverified.",
                isError: true)
        case .writeFailed(let reason):
            return HerdrConfigSaveMessage(text: "Couldn't write config.toml: \(reason)", isError: true)
        }
    }
}
