//
//  KataServer.swift
//  kata-vakta
//
//  Routes protocol messages. Runs on the connection's serial queue.

import Foundation
import KataVaktaCore
import VaktaExtensionKit

final class KataServer {
    private let connection: Connection
    private var contexts: [ExtensionContext] = []

    init(connection: Connection) {
        self.connection = connection
    }

    func handle(_ message: JSONRPCMessage) {
        switch message {
        case let .request(id, ProtocolMethod.initialize, params):
            guard let params, let decoded = try? ExtensionProtocolCodec.decode(InitializeParams.self, from: params),
                  let result = try? ExtensionProtocolCodec.encode(KataServerCore.initializeResult(for: decoded))
            else { return connection.fail(id, code: -32602, "invalid initialize params") }
            connection.respond(to: id, with: result)
        case let .notification(ProtocolMethod.contextsChanged, params):
            guard let params, let decoded = try? ExtensionProtocolCodec.decode(ContextsChangedParams.self, from: params) else { return }
            contexts = decoded.contexts
            connection.log(.info, KataServerCore.describe(contexts))
        case let .request(id, ProtocolMethod.shutdown, _):
            connection.respond(to: id, with: .null)
            exit(0)
        case let .request(id, method, _):
            connection.fail(id, code: -32601, "kata-vakta doesn't handle \(method)")
        default:
            break
        }
    }
}
