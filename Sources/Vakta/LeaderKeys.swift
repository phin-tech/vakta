//
//  LeaderKeys.swift
//  Vakta
//
//  Spacemacs/Doom-style leader keys: press the leader chord, then a short
//  sequence of bare keys walks a tree of groups down to an `AppCommand`
//  (⌘/ w v -> Split Pane Right), with a which-key overlay listing what
//  each next key does. Opt-in (`LeaderSettings.isEnabled`, default off).
//
//  Pure: the tree, the per-key step decision and the overlay rows are value
//  functions. `KeybindingMatcher` owns the pending path and feeds it keys;
//  `LeaderHintPanel` renders `LeaderHintAssembler`'s rows.
//
//  The terminal has no Vim-style normal mode, so unlike Doom's bare SPC the
//  leader must be a chord. Keys *within* a sequence are bare (no ⌃⌥⇧⌘):
//  a modified key cancels.

import AppKit

/// A node of the leader tree: a titled group of keyed children, or a command.
indirect enum LeaderNode: Equatable {
    case group(title: String, children: [LeaderEntry])
    case command(AppCommand)
}

/// One keyed child of a group. `keyCode` is the physical key, like
/// `Keybinding.keyCode`.
struct LeaderEntry: Equatable {
    let keyCode: UInt16
    let node: LeaderNode
}

extension LeaderNode {
    /// The node reached by following `path` from here; `[]` is `self`. `nil`
    /// when a key is unknown or the path runs past a command.
    func node(at path: [UInt16]) -> LeaderNode? {
        var current = self
        for keyCode in path {
            guard case .group(_, let children) = current,
                  let entry = children.first(where: { $0.keyCode == keyCode })
            else { return nil }
            current = entry.node
        }
        return current
    }

    /// Whether anything under this node can run in `context` -- a group
    /// whose commands are all unavailable is hidden and can't be entered.
    func hasAvailableCommand(in context: CommandContext) -> Bool {
        switch self {
        case .command(let command):
            return CommandAvailability.isAvailable(command, in: context)
        case .group(_, let children):
            return children.contains { $0.node.hasAvailableCommand(in: context) }
        }
    }

    /// Each command's key path from here, first occurrence winning -- the
    /// sequence ⌘K shows and searches for a command.
    func commandPaths() -> [AppCommand: [UInt16]] {
        var paths: [AppCommand: [UInt16]] = [:]
        func walk(_ node: LeaderNode, _ path: [UInt16]) {
            switch node {
            case .command(let command):
                if paths[command] == nil { paths[command] = path }
            case .group(_, let children):
                for child in children { walk(child.node, path + [child.keyCode]) }
            }
        }
        walk(self, [])
        return paths
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .group(let title, _): return title
        case .command(let command): return command.title
        }
    }
}

enum LeaderTree {
    // Physical key codes (HIToolbox kVK_ANSI_*), named for the US layout.
    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3, h: UInt16 = 4, g: UInt16 = 5, b: UInt16 = 11, l: UInt16 = 37
        static let z: UInt16 = 6, x: UInt16 = 7, v: UInt16 = 9, q: UInt16 = 12, w: UInt16 = 13
        static let e: UInt16 = 14, r: UInt16 = 15, u: UInt16 = 32, o: UInt16 = 31, p: UInt16 = 35
        static let n: UInt16 = 45, equal: UInt16 = 24, minus: UInt16 = 27, zero: UInt16 = 29
        static let comma: UInt16 = 43, tab: UInt16 = 48, space: UInt16 = 49
    }

    private static func leaf(_ keyCode: UInt16, _ command: AppCommand) -> LeaderEntry {
        LeaderEntry(keyCode: keyCode, node: .command(command))
    }

    private static func group(_ keyCode: UInt16, _ title: String, _ children: [LeaderEntry]) -> LeaderEntry {
        LeaderEntry(keyCode: keyCode, node: .group(title: title, children: children))
    }

    /// The shipped tree, loosely following Doom Emacs conventions (SPC SPC
    /// for the command finder, `w` for windows/panes, TAB for workspaces,
    /// `q q` to quit). Copy/paste/cut/select-all/close-window stay on their
    /// ⌘ chords.
    static let defaultRoot: LeaderNode = .group(title: "Leader", children: [
        leaf(Key.space, .openSessionSwitcher),
        leaf(Key.comma, .openPreferences),
        group(Key.s, "Sessions",
              Keybinding.digitKeyCodes.enumerated().map { leaf($0.element, .selectSession($0.offset)) } + [
                leaf(Key.n, .newSession),
                leaf(Key.u, .nextUnreadSession),
                leaf(Key.x, .stopSession),
              ]),
        group(Key.w, "Panes", [
            leaf(Key.v, .splitPaneRight),
            leaf(Key.s, .splitPaneDown),
            leaf(Key.z, .zoomPane),
            leaf(Key.d, .closePane),
            leaf(Key.r, .renamePane),
        ]),
        group(Key.tab, "Workspaces",
              Keybinding.digitKeyCodes.enumerated().map { leaf($0.element, .focusWorkspace($0.offset)) } + [
                leaf(Key.n, .newWorkspace),
                leaf(Key.d, .closeWorkspace),
              ]),
        group(Key.o, "Open", [
            leaf(Key.p, .toggleSidebar),
            leaf(Key.f, .toggleFileSidebar),
            leaf(Key.g, .toggleFileSidebarChanges),
            leaf(Key.e, .openInEditor),
            leaf(Key.b, .showStatusBarBriefly),
            leaf(Key.v, .cycleStatusBar),
            leaf(Key.r, .openPullRequest),
            leaf(Key.l, .showPullRequests),
        ]),
        group(Key.z, "Font", [
            leaf(Key.equal, .increaseFontSize),
            leaf(Key.minus, .decreaseFontSize),
            leaf(Key.zero, .resetFontSize),
        ]),
        group(Key.h, "Herdr", [
            leaf(Key.e, .editHerdrConfig),
            leaf(Key.r, .reloadHerdrConfig),
        ]),
        group(Key.q, "Quit", [
            leaf(Key.q, .quit),
        ]),
    ])
}

/// What one key does to a pending leader sequence. Every outcome consumes
/// the key; `.cancel` returns to idle without running anything.
enum LeaderStepOutcome: Equatable {
    case descend(path: [UInt16])
    case back(path: [UInt16])
    case commit(AppCommand)
    case cancel
}

enum LeaderSequencePlanner {
    private static let escapeKeyCode: UInt16 = 53
    private static let backspaceKeyCode: UInt16 = 51

    static func step(
        root: LeaderNode,
        path: [UInt16],
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        context: CommandContext
    ) -> LeaderStepOutcome {
        guard modifiers.intersection(SessionSwitcherKeyRouter.relevantModifierMask).isEmpty else { return .cancel }
        if keyCode == escapeKeyCode { return .cancel }
        if keyCode == backspaceKeyCode {
            return path.isEmpty ? .cancel : .back(path: Array(path.dropLast()))
        }
        guard let next = root.node(at: path + [keyCode]),
              next.hasAvailableCommand(in: context)
        else { return .cancel }
        switch next {
        case .command(let command): return .commit(command)
        case .group: return .descend(path: path + [keyCode])
        }
    }
}

/// One which-key row.
struct LeaderHint: Equatable {
    let keyCode: UInt16
    /// Display glyph: lowercase letters, `SPC`/`TAB`, otherwise
    /// `Keybinding.keyGlyph`.
    let key: String
    let title: String
    let isGroup: Bool
    /// The row names what's already current (the focused workspace).
    let isCurrent: Bool
}

enum LeaderHintAssembler {
    /// The rows for the group at `path`, in tree order, hiding commands (and
    /// groups with no commands) that `context` can't run. Empty for a
    /// command or unknown path.
    static func hints(root: LeaderNode, path: [UInt16], context: CommandContext) -> [LeaderHint] {
        guard case .group(_, let children) = root.node(at: path) else { return [] }
        return children
            .filter { $0.node.hasAvailableCommand(in: context) }
            .map { entry in
                LeaderHint(
                    keyCode: entry.keyCode,
                    key: glyph(for: entry.keyCode),
                    title: title(for: entry.node, in: context),
                    isGroup: entry.node.isGroup,
                    isCurrent: entry.node == .command(.focusWorkspace(context.focusedWorkspaceIndex ?? -1))
                )
            }
    }

    /// A session-select or workspace-focus row reads as the session or
    /// workspace it would pick (only ones that exist get a row); everything
    /// else uses its own title.
    private static func title(for node: LeaderNode, in context: CommandContext) -> String {
        switch node {
        case .command(.selectSession(let index)) where context.sessionTitles.indices.contains(index):
            return context.sessionTitles[index]
        case .command(.focusWorkspace(let index)) where context.workspaceTitles.indices.contains(index):
            return context.workspaceTitles[index]
        default:
            return node.title
        }
    }

    static func glyph(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "SPC"
        case 48: return "TAB"
        default:
            let glyph = Keybinding.keyGlyph(for: keyCode)
            return glyph.count == 1 ? glyph.lowercased() : glyph
        }
    }

    /// The breadcrumb for the overlay header, e.g. `⌘/ w`.
    static func breadcrumb(leaderChord: String, path: [UInt16]) -> String {
        ([leaderChord] + path.map(glyph(for:))).joined(separator: " ")
    }

    /// A key path as typed after the leader, e.g. `o f` or `TAB n`.
    static func sequence(for path: [UInt16]) -> String {
        path.map(glyph(for:)).joined(separator: " ")
    }
}

/// The opt-in flag and the leader chord. Persisted in `leader.json`.
struct LeaderSettings: Equatable {
    var isEnabled: Bool = false
    /// Compared exactly, like `Keybinding.modifierMask`.
    var modifierMask: NSEvent.ModifierFlags = .command
    /// `kVK_ANSI_Slash`: ⌘/ by default. Not ⌃Space (macOS's input-source
    /// switch) or ⌘Space (Spotlight); no default `Keybinding` uses ⌘/.
    var keyCode: UInt16 = 44
    /// How long a sequence must stay pending before the which-key overlay
    /// appears, so a memorized sequence typed quickly never flashes it. Stored
    /// raw; use `hintDelay`, which clamps.
    var hintDelayMilliseconds: Int = 300

    static let maximumHintDelayMilliseconds = 2000

    /// `hintDelayMilliseconds` clamped to 0...`maximumHintDelayMilliseconds`
    /// at the point of use, so a hand-edited or extreme value can't stall or
    /// break the overlay.
    var clampedHintDelayMilliseconds: Int {
        min(max(hintDelayMilliseconds, 0), Self.maximumHintDelayMilliseconds)
    }

    var hintDelay: Duration { .milliseconds(clampedHintDelayMilliseconds) }

    var chordDisplayString: String {
        Keybinding.displayString(modifierMask: modifierMask, keyCode: keyCode)
    }
}

extension LeaderSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, modifierMask, keyCode, hintDelayMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LeaderSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        modifierMask = try container.decodeIfPresent(UInt.self, forKey: .modifierMask)
            .map(NSEvent.ModifierFlags.init(rawValue:)) ?? defaults.modifierMask
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? defaults.keyCode
        hintDelayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .hintDelayMilliseconds)
            ?? defaults.hintDelayMilliseconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(modifierMask.rawValue, forKey: .modifierMask)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(hintDelayMilliseconds, forKey: .hintDelayMilliseconds)
    }
}

enum LeaderSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<LeaderSettings>> {
        PersistedFileStore(root: root, fileName: "leader.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<LeaderSettings> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ settings: LeaderSettings, root: URL) -> FileSaveOutcome {
        store(root: root).save(settings)
    }
}
