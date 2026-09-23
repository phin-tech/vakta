//
//  AppCommand.swift
//  Vakta
//
//  The single identity for every app command a user can invoke by chord or
//  from the ⌘K palette (see docs/command-registry-plan.md). Chords
//  (`Keybinding`), palette rows (`PaletteItemKind.command`) and Preferences
//  all name the same case; `AppDelegate.perform(_:)` is the one dispatcher.
//
//  Session, workspace and pane navigation rows are not commands -- they stay
//  distinct `PaletteItemKind`s.

import Foundation

/// What a chord or palette row does. `Codable` (synthesized) so bindings
/// persist across launches (see `KeybindingPersistence`). The synthesized
/// wire shape keys on the case name (`{"toggleSidebar":{}}`,
/// `{"selectSession":{"_0":2}}`), so existing case names and associated-value
/// shapes must never change.
enum AppCommand: Hashable, Codable {
    /// Select the sidebar session at this 0-based index.
    case selectSession(Int)
    /// Collapse/expand the sidebar.
    case toggleSidebar
    /// Open the Preferences window.
    case openPreferences
    /// Open the ⌘K session switcher (command palette).
    case openSessionSwitcher
    /// Quit Vakta.
    case quit
    /// Copy the terminal's current selection to the pasteboard (or the
    /// field editor's selection, when a text field is focused -- see
    /// `AppCommandScope.contextSensitive`).
    case copy
    /// Paste the pasteboard's contents into the terminal (or a focused
    /// text field).
    case paste
    /// Standard Edit-menu cut. The terminal surface has no editable text
    /// to cut, so on the terminal this is a no-op; a focused text field
    /// cuts normally.
    case cut
    /// Select the terminal's entire scrollback (or a focused text field's
    /// contents).
    case selectAll
    /// Close the frontmost window. A normal, user-clearable binding like
    /// every other action -- some users route this chord to a terminal
    /// multiplexer running *inside* the session instead (e.g. closing a
    /// pane), and clear this binding so the keystroke reaches the terminal.
    case closeWindow
    /// Grow the terminal's font size (Ghostty's `increase_font_size` binding
    /// action on the selected session's surface).
    case increaseFontSize
    /// Shrink the terminal's font size (`decrease_font_size`).
    case decreaseFontSize
    /// Reset the terminal's font size to the configured default
    /// (`reset_font_size`).
    case resetFontSize
    /// Jump to the next session with an unseen attention transition (the
    /// bell popover's cmux-style "next unread" -- see
    /// `NextUnreadSessionPlanner`). Defaults to ⌘U; rebindable/clearable
    /// like every other action.
    case nextUnreadSession
    /// Launch a new session from the default profile.
    case newSession
    /// Show/hide the right-hand file sidebar.
    case toggleFileSidebar
    /// Show the file sidebar's git Changes view, or flip it back to Files
    /// (see `FileSidebarModePlanner.togglingChanges`).
    case toggleFileSidebarChanges
    /// Open the focused pane's working directory in the preferred editor.
    case openInEditor
    /// Reveal the status bar for a while in any mode (again: hide it).
    case showStatusBarBriefly
    /// Step the status bar through Automatic → Auto-hide → Always → Never.
    case cycleStatusBar
    /// Open the selected session's focused-pane PR in the browser; a no-op
    /// when that pane's branch has no open PR.
    case openPullRequest
    // The mutating multiplexer commands (see `MultiplexerAction`). They act
    // on the selected session's focused workspace/pane and require a backend
    // that vends them -- see `CommandAvailability`.
    case splitPaneRight
    case splitPaneDown
    case zoomPane
    case closePane
    case renamePane
    case closeWorkspace
    case newWorkspace
    case stopSession
    /// Open Preferences on the herdr config pane.
    case editHerdrConfig
    /// Ask the running herdr server to re-read its config.
    case reloadHerdrConfig
    /// Focus the selected session's workspace (herdr workspace / tmux window)
    /// at this 0-based position in its workspace list.
    case focusWorkspace(Int)
    /// Reopen the first-launch welcome tour.
    case showWelcomeTour
    /// Show every release note up to the running version.
    case showWhatsNew

    /// The one label shared by the palette, Preferences and (later)
    /// which-key.
    var title: String {
        switch self {
        case .selectSession(let index): return "Select Session \(index + 1)"
        case .toggleSidebar: return "Toggle Sidebar"
        case .openPreferences: return "Open Preferences"
        case .openSessionSwitcher: return "Command Palette"
        case .quit: return "Quit"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .cut: return "Cut"
        case .selectAll: return "Select All"
        case .closeWindow: return "Close Window"
        case .increaseFontSize: return "Increase Font Size"
        case .decreaseFontSize: return "Decrease Font Size"
        case .resetFontSize: return "Reset Font Size"
        case .nextUnreadSession: return "Next Unread Session"
        case .newSession: return "New Session"
        case .toggleFileSidebar: return "Toggle File Sidebar"
        case .toggleFileSidebarChanges: return "Toggle File Sidebar Git Changes"
        case .openInEditor: return "Open in Editor"
        case .showStatusBarBriefly: return "Show Status Bar Briefly"
        case .cycleStatusBar: return "Cycle Status Bar Visibility"
        case .openPullRequest: return "Open Pull Request"
        case .splitPaneRight: return "Split Pane Right"
        case .splitPaneDown: return "Split Pane Down"
        case .zoomPane: return "Zoom Pane"
        case .closePane: return "Close Pane"
        case .renamePane: return "Rename Pane…"
        case .closeWorkspace: return "Close Workspace"
        case .newWorkspace: return "New Workspace"
        case .stopSession: return "Stop Session"
        case .editHerdrConfig: return "Edit Herdr Config…"
        case .reloadHerdrConfig: return "Reload Herdr Config"
        case .focusWorkspace(let index): return "Focus Workspace \(index + 1)"
        case .showWelcomeTour: return "Show Welcome Tour"
        case .showWhatsNew: return "What's New in Vakta"
        }
    }

    /// A stable string name: the palette row id today (`"action:<stableID>"`,
    /// unchanged from the pre-registry string ids) and a human-editable
    /// config key later. Never derived from `title`.
    var stableID: String {
        switch self {
        case .selectSession(let index): return "selectSession.\(index)"
        case .toggleSidebar: return "toggleSidebar"
        case .openPreferences: return "openPreferences"
        case .openSessionSwitcher: return "openSessionSwitcher"
        case .quit: return "quit"
        case .copy: return "copy"
        case .paste: return "paste"
        case .cut: return "cut"
        case .selectAll: return "selectAll"
        case .closeWindow: return "closeWindow"
        case .increaseFontSize: return "increaseFontSize"
        case .decreaseFontSize: return "decreaseFontSize"
        case .resetFontSize: return "resetFontSize"
        case .nextUnreadSession: return "nextUnreadSession"
        case .newSession: return "newSession"
        case .toggleFileSidebar: return "toggleFileSidebar"
        case .toggleFileSidebarChanges: return "toggleFileSidebarChanges"
        case .openInEditor: return "openInEditor"
        case .showStatusBarBriefly: return "showStatusBarBriefly"
        case .cycleStatusBar: return "cycleStatusBar"
        case .openPullRequest: return "openPullRequest"
        case .splitPaneRight: return "splitPaneRight"
        case .splitPaneDown: return "splitPaneDown"
        case .zoomPane: return "zoomPane"
        case .closePane: return "closePane"
        case .renamePane: return "renamePane"
        case .closeWorkspace: return "closeWorkspace"
        case .newWorkspace: return "newWorkspace"
        case .stopSession: return "stopSession"
        case .editHerdrConfig: return "editHerdrConfig"
        case .reloadHerdrConfig: return "reloadHerdrConfig"
        case .focusWorkspace(let index): return "focusWorkspace.\(index)"
        case .showWelcomeTour: return "showWelcomeTour"
        case .showWhatsNew: return "showWhatsNew"
        }
    }

    /// What must hold for the command to be offered (palette) or to take
    /// effect (dispatch).
    var requirement: AppCommandRequirement {
        switch self {
        case .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane,
             .closeWorkspace, .newWorkspace, .stopSession:
            return .multiplexerActions
        case .selectSession(let index):
            return .session(at: index)
        case .focusWorkspace(let index):
            return .workspace(at: index)
        case .toggleSidebar, .openPreferences, .openSessionSwitcher, .quit,
             .copy, .paste, .cut, .selectAll, .closeWindow,
             .increaseFontSize, .decreaseFontSize, .resetFontSize, .nextUnreadSession,
             .newSession, .toggleFileSidebar, .toggleFileSidebarChanges, .openInEditor,
             .showStatusBarBriefly, .cycleStatusBar, .openPullRequest,
             .editHerdrConfig, .reloadHerdrConfig,
             .showWelcomeTour, .showWhatsNew:
            return .none
        }
    }

    /// Grouping for Preferences (and, later, default leader-key groups).
    var group: AppCommandGroup {
        switch self {
        case .openSessionSwitcher, .openPreferences, .toggleSidebar, .toggleFileSidebar,
             .toggleFileSidebarChanges, .openInEditor, .quit, .closeWindow, .copy, .paste, .cut, .selectAll,
             .showWelcomeTour, .showWhatsNew, .showStatusBarBriefly, .cycleStatusBar, .openPullRequest:
            return .application
        case .selectSession, .newSession, .nextUnreadSession, .stopSession:
            return .sessions
        case .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane:
            return .panes
        case .newWorkspace, .closeWorkspace, .focusWorkspace:
            return .workspaces
        case .increaseFontSize, .decreaseFontSize, .resetFontSize:
            return .font
        case .editHerdrConfig, .reloadHerdrConfig:
            return .herdr
        }
    }
}

enum AppCommandRequirement: Equatable {
    case none
    /// The selected session's backend must vend the mutating multiplexer
    /// commands (`LaunchTargetResolver.supportsActions`).
    case multiplexerActions
    /// A session must exist at this 0-based sidebar position.
    case session(at: Int)
    /// The selected session must have a workspace at this 0-based position.
    case workspace(at: Int)
}

enum AppCommandGroup: CaseIterable {
    case application
    case sessions
    case panes
    case workspaces
    case font
    case herdr

    var title: String {
        switch self {
        case .application: return "Application"
        case .sessions: return "Sessions"
        case .panes: return "Panes"
        case .workspaces: return "Workspaces"
        case .font: return "Font"
        case .herdr: return "Herdr"
        }
    }
}

/// The hand-ordered command lists. Exhaustive switches on `AppCommand` force
/// metadata for a new case, but not membership here -- add a new case to
/// these lists explicitly.
enum AppCommandCatalog {
    /// The ⌘K static rows, in display order, before availability filtering.
    static let paletteCommands: [AppCommand] = [
        .newSession, .toggleSidebar, .toggleFileSidebar, .openPreferences, .openInEditor,
        .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane,
        .closeWorkspace, .newWorkspace, .stopSession,
        .editHerdrConfig, .reloadHerdrConfig,
        .increaseFontSize, .decreaseFontSize, .resetFontSize,
        .toggleFileSidebarChanges,
        .showWelcomeTour, .showWhatsNew,
        .showStatusBarBriefly, .cycleStatusBar, .openPullRequest,
    ]

    /// Every command Preferences lets the user bind, in display order within
    /// each `group`. Session selection covers the nine default chords; a
    /// persisted `selectSession` with another index still decodes and
    /// matches, it just has no Preferences row.
    static let bindableCommands: [AppCommand] = [
        .openSessionSwitcher, .openPreferences, .toggleSidebar, .toggleFileSidebar, .toggleFileSidebarChanges,
        .openInEditor, .showStatusBarBriefly, .cycleStatusBar, .openPullRequest, .quit, .closeWindow, .copy, .paste, .cut, .selectAll,
    ]
        + (0..<9).map { AppCommand.selectSession($0) }
        + [
            .newSession, .nextUnreadSession, .stopSession,
            .splitPaneRight, .splitPaneDown, .zoomPane, .closePane, .renamePane,
            .newWorkspace, .closeWorkspace,
        ]
        + (0..<9).map { AppCommand.focusWorkspace($0) }
        + [
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .editHerdrConfig, .reloadHerdrConfig,
            .showWelcomeTour, .showWhatsNew,
        ]
}

/// The shell-supplied snapshot `CommandAvailability` decides against.
struct CommandContext: Equatable {
    /// A session is selected and `LaunchTargetResolver.supportsActions` is
    /// true for it.
    var supportsSelectedSessionActions: Bool
    /// The open sessions' display titles in sidebar order -- what
    /// `selectSession(i)` would select, and its label in the which-key rows.
    var sessionTitles: [String] = []
    /// The selected session's workspace labels in its own order (from the
    /// `SessionStore` cache) -- what `focusWorkspace(i)` would focus.
    var workspaceTitles: [String] = []
    /// Which of `workspaceTitles` is focused, if known.
    var focusedWorkspaceIndex: Int?

    /// Nothing selected, nothing open: every command with a requirement is
    /// unavailable.
    static let empty = CommandContext(supportsSelectedSessionActions: false)
}

enum CommandAvailability {
    /// Whether `command` should be offered in the palette, and whether a
    /// dispatch of it (palette or chord) should take effect. An unavailable
    /// bound chord is still consumed by the matcher; the dispatcher no-ops.
    static func isAvailable(_ command: AppCommand, in context: CommandContext) -> Bool {
        switch command.requirement {
        case .none: return true
        case .multiplexerActions: return context.supportsSelectedSessionActions
        case .session(let index): return context.sessionTitles.indices.contains(index)
        case .workspace(let index): return context.workspaceTitles.indices.contains(index)
        }
    }
}
