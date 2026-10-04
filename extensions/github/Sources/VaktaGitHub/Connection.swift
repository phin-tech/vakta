//
//  Connection.swift
//  vakta-github
//
//  The stdio side of the Vakta Extension protocol: reads one JSON-RPC
//  message per line from stdin on a background thread and hands each to a
//  serial queue; writes are serialized. stdin closing means Vakta is gone.

import Foundation
import VaktaExtensionKit

final class Connection: @unchecked Sendable {
    let queue = DispatchQueue(label: "vakta-github.connection")
    private let writeLock = NSLock()

    func send(_ message: JSONRPCMessage) {
        guard let line = try? ExtensionProtocolCodec.encodeLine(message) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func log(_ level: LogParams.Level, _ message: String) {
        guard let params = try? ExtensionProtocolCodec.encode(LogParams(level: level, message: message)) else { return }
        send(.notification(method: ProtocolMethod.log, params: params))
    }

    func respond(to id: JSONRPCID, with result: JSONValue) {
        send(.response(id: id, result: result))
    }

    func fail(_ id: JSONRPCID, code: Int = -32603, _ message: String) {
        send(.errorResponse(id: id, error: JSONRPCError(code: code, message: message)))
    }

    /// Blocks reading stdin until EOF, dispatching each message to `handle`
    /// on `queue`.
    func run(_ handle: @escaping (JSONRPCMessage) -> Void) -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let message = try? ExtensionProtocolCodec.decodeLine(line) else {
                FileHandle.standardError.write(Data("vakta-github: ignored malformed line\n".utf8))
                continue
            }
            queue.sync { handle(message) }
        }
        exit(0)
    }
}
