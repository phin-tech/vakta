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

public struct ExtensionContext: Codable, Equatable, Sendable {
    public var sessionKey: SessionKey
    public var cwd: String?
    public var gitRoot: String?
    public var branch: String?
    public var workspace: WorkspaceRef?
    public var focused: Bool

    public init(
        sessionKey: SessionKey, cwd: String?, gitRoot: String?, branch: String?,
        workspace: WorkspaceRef?, focused: Bool
    ) {
        self.sessionKey = sessionKey
        self.cwd = cwd
        self.gitRoot = gitRoot
        self.branch = branch
        self.workspace = workspace
        self.focused = focused
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

public struct StatusSetParams: Codable, Equatable, Sendable {
    public var text: String
    public var symbol: String?
    public var popover: ViewDocument?

    public init(text: String, symbol: String?, popover: ViewDocument?) {
        self.text = text
        self.symbol = symbol
        self.popover = popover
    }
}

public struct BadgeSetParams: Codable, Equatable, Sendable {
    public var sessionKey: SessionKey
    public var text: String
    public var symbol: String?
    public var popover: ViewDocument?

    public init(sessionKey: SessionKey, text: String, symbol: String?, popover: ViewDocument?) {
        self.sessionKey = sessionKey
        self.text = text
        self.symbol = symbol
        self.popover = popover
    }
}

public struct BadgeClearParams: Codable, Equatable, Sendable {
    public var sessionKey: SessionKey

    public init(sessionKey: SessionKey) {
        self.sessionKey = sessionKey
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
