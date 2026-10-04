//
//  ExtensionHarness.swift
//  VaktaExtensionServer
//
//  Drives an ExtensionServer in memory, the way Vakta would, so an
//  Extension's behavior can be tested without Vakta or a child process.

import Foundation
import VaktaExtensionKit

public final class ExtensionHarness {
    /// Collects what the server sends.
    public final class MemoryTransport: ExtensionTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        public init() {}

        public func send(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var messages: [JSONRPCMessage] {
            lock.lock()
            defer { lock.unlock() }
            return lines.compactMap { try? ExtensionProtocolCodec.decodeLine($0) }
        }
    }

    public let transport = MemoryTransport()
    public private(set) var server: ExtensionServer!
    /// Whether `shutdown` asked the process to exit.
    public private(set) var exited = false
    private var nextID = 1

    /// `make` builds the Extension around the given transport.
    public init(_ make: (ExtensionTransport) -> ExtensionServer) {
        server = make(transport)
        server.exit = { [weak self] in self?.exited = true }
    }

    /// Everything the server has sent so far.
    public var sent: [JSONRPCMessage] {
        server.queue.sync {}
        return transport.messages
    }

    /// Notifications with `method`, decoded as `T`.
    public func notifications<T: Decodable>(_ method: String, as type: T.Type) -> [T] {
        sent.compactMap { message in
            guard case let .notification(sentMethod, params?) = message, sentMethod == method else { return nil }
            return try? ExtensionProtocolCodec.decode(type, from: params)
        }
    }

    /// Notifications with `method` that carry no params (like `status/clear`).
    public func count(_ method: String) -> Int {
        sent.filter { if case let .notification(sentMethod, _) = $0 { return sentMethod == method }; return false }.count
    }

    @discardableResult
    public func initialize() throws -> InitializeResult {
        let params = InitializeParams(apiVersion: vaktaExtensionAPIVersion, host: HostInfo(name: "Harness", version: "0"),
                                      capabilities: HostCapabilities(viewKinds: ["list", "detail", "form"], effects: []))
        return try ExtensionProtocolCodec.decode(InitializeResult.self, from: try request(ProtocolMethod.initialize, params))
    }

    public func send(contexts: [ExtensionContext]) {
        deliver(.notification(method: ProtocolMethod.contextsChanged,
                              params: try? ExtensionProtocolCodec.encode(ContextsChangedParams(contexts: contexts))))
    }

    public func render(_ view: String) throws -> ViewDocument {
        try ExtensionProtocolCodec.decode(ViewDocument.self, from: try request(ProtocolMethod.viewRender, ViewRenderParams(view: view)))
    }

    public func callback(_ name: String, view: String = "test", payload: JSONValue? = nil, form: [String: JSONValue]? = nil) throws -> [Effect] {
        let params = CallbackParams(view: view, callback: name, payload: payload, form: form)
        return try ExtensionProtocolCodec.decode(CallbackResult.self, from: try request(ProtocolMethod.callback, params)).effects
    }

    public func shutdown() throws {
        _ = try request(ProtocolMethod.shutdown, Optional<String>.none)
    }

    /// Sends a request and returns its result; an error response throws.
    public func request<Params: Encodable>(_ method: String, _ params: Params?) throws -> JSONValue {
        let id = nextID
        nextID += 1
        let encoded = try params.map { try ExtensionProtocolCodec.encode($0) }
        deliver(.request(id: .number(id), method: method, params: encoded))
        for message in sent {
            switch message {
            case let .response(.number(id2), result) where id2 == id: return result
            case let .errorResponse(.number(id2)?, error) where id2 == id: throw ExtensionError(error.message, code: error.code)
            default: continue
            }
        }
        throw ExtensionError("no response to \(method)")
    }

    private func deliver(_ message: JSONRPCMessage) {
        server.queue.sync { server.handle(message) }
    }
}
