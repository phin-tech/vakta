//
//  Messages.swift
//  VaktaExtensionKit
//
//  Typed params and results for each protocol method. Field names follow
//  the JSON keys in extensions/protocol/fixtures; see docs/extensions-plan.md
//  for what each message means.

import Foundation

public enum ProtocolMethod {
    // Host → Extension
    public static let initialize = "initialize"
    public static let contextsChanged = "contexts/changed"
    public static let viewRender = "view/render"
    public static let callback = "callback"
    public static let cancel = "$/cancel"
    public static let shutdown = "shutdown"
    // Extension → host
    public static let viewUpdate = "view/update"
    public static let viewInvalidate = "view/invalidate"
    public static let statusSet = "status/set"
    public static let statusClear = "status/clear"
    public static let badgeSet = "badge/set"
    public static let badgeClear = "badge/clear"
    public static let log = "log"
    public static let notify = "notify"
    public static let commandsSet = "commands/set"
}

// MARK: - initialize

public struct HostInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct HostCapabilities: Codable, Equatable, Sendable {
    /// View Document kinds this host draws (`list`, `detail`, `form`).
    public var viewKinds: [String]
    /// Effect types this host carries out.
    public var effects: [String]

    public init(viewKinds: [String], effects: [String]) {
        self.viewKinds = viewKinds
        self.effects = effects
    }
}

public struct InitializeParams: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var host: HostInfo
    public var capabilities: HostCapabilities

    public init(apiVersion: Int, host: HostInfo, capabilities: HostCapabilities) {
        self.apiVersion = apiVersion
        self.host = host
        self.capabilities = capabilities
    }
}

public struct InitializeResult: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var name: String

    public init(apiVersion: Int, name: String) {
        self.apiVersion = apiVersion
        self.name = name
    }
}

// MARK: - Extension Context

/// A Session's identity across Vakta restarts: backend plus the
/// multiplexer's session name. `backend` stays a string so a newer host's
/// backend doesn't fail an older Extension's decode.
public struct SessionKey: Codable, Hashable, Sendable {
    public var backend: String
    public var sessionName: String

    public init(backend: String, sessionName: String) {
        self.backend = backend
        self.sessionName = sessionName
    }
}

public struct WorkspaceRef: Codable, Equatable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One pane's location, sent only to Extensions whose manifest asks for
/// panes (`"contexts": "panes"`).
public struct PaneContext: Codable, Equatable, Sendable {
    public var paneID: String
    public var workspace: WorkspaceRef?
    public var cwd: String?
    public var gitRoot: String?
    public var branch: String?
    public var focused: Bool

    public init(paneID: String, workspace: WorkspaceRef?, cwd: String?, gitRoot: String?, branch: String?, focused: Bool) {
        self.paneID = paneID
        self.workspace = workspace
        self.cwd = cwd
        self.gitRoot = gitRoot
        self.branch = branch
        self.focused = focused
    }
}

public struct ExtensionContext: Codable, Equatable, Sendable {
    public var sessionKey: SessionKey
    public var cwd: String?
    public var gitRoot: String?
    public var branch: String?
    public var workspace: WorkspaceRef?
    public var focused: Bool
    /// Every pane in the Session; `nil` unless the Extension opted in.
    public var panes: [PaneContext]?

    public init(
        sessionKey: SessionKey, cwd: String?, gitRoot: String?, branch: String?,
        workspace: WorkspaceRef?, focused: Bool, panes: [PaneContext]? = nil
    ) {
        self.sessionKey = sessionKey
        self.cwd = cwd
        self.gitRoot = gitRoot
        self.branch = branch
        self.workspace = workspace
        self.focused = focused
        self.panes = panes
    }
}

/// A full snapshot: every Session, not a delta.
public struct ContextsChangedParams: Codable, Equatable, Sendable {
    public var contexts: [ExtensionContext]

    public init(contexts: [ExtensionContext]) {
        self.contexts = contexts
    }
}

// MARK: - Views, Callbacks

public struct ViewRenderParams: Codable, Equatable, Sendable {
    public var view: String

    public init(view: String) {
        self.view = view
    }
}

public struct CallbackParams: Codable, Equatable, Sendable {
    public var view: String
    public var callback: String
    public var payload: JSONValue?
    /// Field id → value, present when a form's submit button sent this.
    public var form: [String: JSONValue]?

    public init(view: String, callback: String, payload: JSONValue?, form: [String: JSONValue]?) {
        self.view = view
        self.callback = callback
        self.payload = payload
        self.form = form
    }
}

public struct CallbackResult: Codable, Equatable, Sendable {
    public var effects: [Effect]

    public init(effects: [Effect]) {
        self.effects = effects
    }
}

public struct CancelParams: Codable, Equatable, Sendable {
    public var id: JSONRPCID

    public init(id: JSONRPCID) {
        self.id = id
    }
}

public struct ViewUpdateParams: Codable, Equatable, Sendable {
    public var view: String
    public var document: ViewDocument

    public init(view: String, document: ViewDocument) {
        self.view = view
        self.document = document
    }
}

public struct ViewInvalidateParams: Codable, Equatable, Sendable {
    public var view: String

    public init(view: String) {
        self.view = view
    }
}

// MARK: - Status Item, Session Badges, log

/// One piece of a Status Item.
public struct StatusSegment: Equatable, Sendable {
    /// Vakta picks the actual colors (green stays reserved for "ready").
    public enum Tint: String, Sendable {
        case neutral, success, warning, failure
    }

    public var text: String
    public var symbol: String?
    public var tint: Tint
    public var help: String?
    /// Clicking the segment sends this button's Callback.
    public var action: ViewButton?
    /// Clicking the segment opens this http(s) URL (when there's no action).
    public var url: String?
    public var popover: ViewDocument?
    /// Turning this on peeks an Auto-hide status bar.
    public var attention: Bool
    /// Overrides the item's placement for this segment (an item can show a
    /// leading part and a trailing summary).
    public var placement: StatusSetParams.Placement?

    public init(
        text: String, symbol: String? = nil, tint: Tint = .neutral, help: String? = nil, action: ViewButton? = nil,
        url: String? = nil, popover: ViewDocument? = nil, attention: Bool = false, placement: StatusSetParams.Placement? = nil
    ) {
        self.placement = placement
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.help = help
        self.action = action
        self.url = url
        self.popover = popover
        self.attention = attention
    }
}

public struct StatusSetParams: Equatable, Sendable {
    public enum Placement: String, Sendable {
        /// Beside the focused pane's branch, on the left.
        case leading
        /// The right side, for summaries.
        case trailing
    }

    public var placement: Placement
    public var segments: [StatusSegment]

    public init(placement: Placement, segments: [StatusSegment]) {
        self.placement = placement
        self.segments = segments
    }

    /// The original single-text item: one neutral trailing segment.
    public init(text: String, symbol: String?, popover: ViewDocument?) {
        self.init(placement: .trailing, segments: [StatusSegment(text: text, symbol: symbol, popover: popover)])
    }
}

public struct BadgeSetParams: Equatable, Sendable {
    public var sessionKey: SessionKey
    public var text: String
    public var symbol: String?
    public var tint: StatusSegment.Tint
    public var popover: ViewDocument?

    public init(sessionKey: SessionKey, text: String, symbol: String?, tint: StatusSegment.Tint = .neutral, popover: ViewDocument?) {
        self.sessionKey = sessionKey
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.popover = popover
    }
}

public struct BadgeClearParams: Codable, Equatable, Sendable {
    public var sessionKey: SessionKey

    public init(sessionKey: SessionKey) {
        self.sessionKey = sessionKey
    }
}

/// A notification an Extension asks for; Vakta decides whether to show it.
public struct NotifyParams: Codable, Equatable, Sendable {
    public var title: String
    public var body: String?
    /// The Session it's about (clicking surfaces it; suppressed while you're looking at it).
    public var sessionKey: SessionKey?

    public init(title: String, body: String?, sessionKey: SessionKey?) {
        self.title = title
        self.body = body
        self.sessionKey = sessionKey
    }
}

/// A ⌘K Command an Extension offers while it applies.
public struct ExtensionCommand: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var callback: String
    public var payload: JSONValue?

    public init(id: String, title: String, symbol: String?, callback: String, payload: JSONValue?) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.callback = callback
        self.payload = payload
    }
}

/// The full set of an Extension's current Commands (replaces the previous set).
public struct CommandsSetParams: Codable, Equatable, Sendable {
    public var commands: [ExtensionCommand]

    public init(commands: [ExtensionCommand]) {
        self.commands = commands
    }
}

public struct LogParams: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case debug, info, warning, error
    }

    public var level: Level
    public var message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }
}
