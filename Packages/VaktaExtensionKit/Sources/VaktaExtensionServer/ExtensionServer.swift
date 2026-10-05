//
//  ExtensionServer.swift
//  VaktaExtensionServer
//
//  The runtime for a Swift Vakta Extension: reads one JSON-RPC message per
//  line, answers the handshake and shutdown, routes `view/render` and
//  `callback` to registered handlers (a thrown `ExtensionError` becomes an
//  error response), keeps the current Extension Contexts, and publishes
//  Status Items, Session Badges and Commands, sending only what changed.
//
//  Everything runs on `queue` (serial): messages, `after` timers, and any
//  work an Extension schedules with `queue.async`, so handlers never race.

import Foundation
import VaktaExtensionKit

/// Where protocol lines go: stdout for a real Extension, memory in tests.
public protocol ExtensionTransport: AnyObject {
    func send(_ line: String)
}

/// Writes lines to stdout, serialized.
public final class StandardOutputTransport: ExtensionTransport, @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func send(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

/// Thrown from a handler to answer the request with an error.
public struct ExtensionError: Error, Equatable {
    public var code: Int
    public var message: String

    public init(_ message: String, code: Int = -32603) {
        self.code = code
        self.message = message
    }

    public static func invalidParams(_ message: String) -> ExtensionError { ExtensionError(message, code: -32602) }
}

public final class ExtensionServer: @unchecked Sendable {
    public let name: String
    public let queue: DispatchQueue

    /// The latest snapshot: one Extension Context per Session.
    public private(set) var contexts: [ExtensionContext] = []
    public var focusedContext: ExtensionContext? { contexts.first(where: \.focused) }

    /// After the handshake.
    public var onReady: (() -> Void)?
    /// A new contexts snapshot (previous, current).
    public var onContexts: ((_ previous: [ExtensionContext], _ current: [ExtensionContext]) -> Void)?
    /// Before the process exits on `shutdown`.
    public var onShutdown: (() -> Void)?
    /// How the process ends after `shutdown`; tests replace it.
    public var exit: () -> Void = { Foundation.exit(0) }

    private let transport: ExtensionTransport
    private var renderers: [String: () throws -> ViewDocument] = [:]
    private var callbacks: [String: (CallbackParams) throws -> [Effect]] = [:]
    private var lastStatus: StatusSetParams??
    private var badges: [SessionKey: BadgeSetParams] = [:]
    private var commands: [ExtensionCommand]?

    public init(name: String, transport: ExtensionTransport = StandardOutputTransport()) {
        self.name = name
        self.transport = transport
        queue = DispatchQueue(label: "vakta-extension.\(name)")
    }

    // MARK: - Handlers

    /// Answers `view/render` for `view`.
    public func onRender(_ view: String, _ handler: @escaping () throws -> ViewDocument) {
        renderers[view] = handler
    }

    /// Answers a button's Callback `name` with Effects.
    public func onCallback(_ name: String, _ handler: @escaping (CallbackParams) throws -> [Effect]) {
        callbacks[name] = handler
    }

    // MARK: - Running

    /// Reads stdin until Vakta closes it. Never returns.
    public func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            queue.sync { receive(line: line) }
        }
        Foundation.exit(0)
    }

    /// Handles one protocol line. Call on `queue`.
    public func receive(line: String) {
        guard let message = try? ExtensionProtocolCodec.decodeLine(line) else {
            FileHandle.standardError.write(Data("\(name): ignored a malformed line\n".utf8))
            return
        }
        handle(message)
    }

    /// Handles one message. Call on `queue`.
    public func handle(_ message: JSONRPCMessage) {
        switch message {
        case let .request(id, method, params):
            request(id: id, method: method, params: params)
        case let .notification(ProtocolMethod.contextsChanged, params?):
            guard let decoded = try? ExtensionProtocolCodec.decode(ContextsChangedParams.self, from: params) else { return }
            let previous = contexts
            contexts = decoded.contexts
            onContexts?(previous, contexts)
        default:
            break
        }
    }

    /// Runs `work` on `queue` after `delay`.
    public func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func request(id: JSONRPCID, method: String, params: JSONValue?) {
        do {
            switch method {
            case ProtocolMethod.initialize:
                respond(id, try ExtensionProtocolCodec.encode(InitializeResult(apiVersion: vaktaExtensionAPIVersion, name: name)))
                onReady?()
            case ProtocolMethod.viewRender:
                guard let params, let render = try? ExtensionProtocolCodec.decode(ViewRenderParams.self, from: params) else {
                    throw ExtensionError.invalidParams("invalid view/render params")
                }
                guard let renderer = renderers[render.view] else { throw ExtensionError.invalidParams("no view \(render.view)") }
                respond(id, try ExtensionProtocolCodec.encode(try renderer()))
            case ProtocolMethod.callback:
                guard let params, let callback = try? ExtensionProtocolCodec.decode(CallbackParams.self, from: params) else {
                    throw ExtensionError.invalidParams("invalid callback params")
                }
                guard let handler = callbacks[callback.callback] else {
                    throw ExtensionError("unknown action \(callback.callback)", code: -32601)
                }
                respond(id, try ExtensionProtocolCodec.encode(CallbackResult(effects: try handler(callback))))
            case ProtocolMethod.shutdown:
                respond(id, .null)
                onShutdown?()
                exit()
            default:
                throw ExtensionError("\(name) doesn't handle \(method)", code: -32601)
            }
        } catch let error as ExtensionError {
            send(.errorResponse(id: id, error: JSONRPCError(code: error.code, message: error.message)))
        } catch {
            send(.errorResponse(id: id, error: JSONRPCError(code: -32603, message: "\(error)")))
        }
    }

    // MARK: - Publishing (only changes are sent)

    /// The Status Item, or nil to clear it.
    public func setStatus(_ status: StatusSetParams?) {
        guard lastStatus != .some(status) else { return }
        if let status {
            guard notify(ProtocolMethod.statusSet, status) else { return }
        } else {
            send(.notification(method: ProtocolMethod.statusClear, params: nil))
        }
        lastStatus = .some(status)
    }

    /// Every Session Badge, keyed by Session; Sessions left out are cleared.
    /// Indexed by each badge's own `sessionKey`, not the caller's dictionary
    /// key, so a mismatched key can't orphan or misname a clear. A badge
    /// that fails to encode is left out of the recorded state, so dedup
    /// doesn't silently treat an undelivered push as sent.
    public func setBadges(_ next: [SessionKey: BadgeSetParams]) {
        let next = Dictionary(next.values.map { ($0.sessionKey, $0) }, uniquingKeysWith: { _, last in last })
        var stored = badges
        for (key, badge) in next where badges[key] != badge {
            guard notify(ProtocolMethod.badgeSet, badge) else { continue }
            stored[key] = badge
        }
        for key in badges.keys where next[key] == nil {
            notify(ProtocolMethod.badgeClear, BadgeClearParams(sessionKey: key))
            stored[key] = nil
        }
        badges = stored
    }

    /// The Commands that currently apply (replaces the previous set).
    public func setCommands(_ next: [ExtensionCommand]) {
        guard next != commands else { return }
        guard notify(ProtocolMethod.commandsSet, CommandsSetParams(commands: next)) else { return }
        commands = next
    }

    /// A notification through Vakta's attention path.
    public func notify(title: String, body: String? = nil, sessionKey: SessionKey? = nil) {
        notify(ProtocolMethod.notify, NotifyParams(title: title, body: body, sessionKey: sessionKey))
    }

    /// Asks Vakta to re-render `view`.
    public func invalidate(view: String) {
        notify(ProtocolMethod.viewInvalidate, ViewInvalidateParams(view: view))
    }

    /// Pushes a new document for `view`.
    public func update(view: String, document: ViewDocument) {
        notify(ProtocolMethod.viewUpdate, ViewUpdateParams(view: view, document: document))
    }

    public func log(_ level: LogParams.Level, _ message: String) {
        notify(ProtocolMethod.log, LogParams(level: level, message: message))
    }

    /// Sends `params` as a notification; `false` (nothing sent) if it
    /// couldn't be encoded.
    @discardableResult
    private func notify<Params: Encodable>(_ method: String, _ params: Params) -> Bool {
        guard let encoded = try? ExtensionProtocolCodec.encode(params) else { return false }
        send(.notification(method: method, params: encoded))
        return true
    }

    private func respond(_ id: JSONRPCID, _ result: JSONValue) {
        send(.response(id: id, result: result))
    }

    private func send(_ message: JSONRPCMessage) {
        guard let line = try? ExtensionProtocolCodec.encodeLine(message) else { return }
        transport.send(line)
    }
}
