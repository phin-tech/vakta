//
//  JSONRPC.swift
//  VaktaExtensionKit
//
//  The envelope for every message between Vakta and an Extension:
//  JSON-RPC 2.0, one object per line on stdio. `JSONValue` carries params
//  and results untyped; `ExtensionProtocolCodec` converts them to the typed
//  payloads in Messages.swift.

import Foundation

/// The protocol version exchanged in `initialize`. A mismatch marks the
/// Extension Failed.
public let vaktaExtensionAPIVersion = 1

/// Any JSON value, for params and results whose type depends on the method.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public enum JSONRPCID: Hashable, Sendable {
    case number(Int)
    case string(String)
}

public struct JSONRPCError: Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public enum JSONRPCMessage: Equatable, Sendable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONRPCID, result: JSONValue)
    /// `id` is nil when the failing request's id couldn't be read.
    case errorResponse(id: JSONRPCID?, error: JSONRPCError)
}

public enum ExtensionProtocolError: Error, Equatable {
    /// The line isn't a JSON object.
    case malformedLine
    /// The object isn't JSON-RPC 2.0: missing or wrong `"jsonrpc"`, or no
    /// recognizable request/notification/response shape.
    case notJSONRPC
    /// Params or a result didn't match the expected payload type.
    case payloadMismatch(String)
}

/// Converts between protocol lines, envelopes and typed payloads. Pure: no
/// I/O; the caller owns reading and writing the pipes.
public enum ExtensionProtocolCodec {
    /// One message as a single line, terminated by `\n` and containing no
    /// other newline. (JSON encoding escapes newlines inside strings.)
    public static func encodeLine(_ message: JSONRPCMessage) throws -> String {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch message {
        case let .request(id, method, params):
            object["id"] = id.jsonValue
            object["method"] = .string(method)
            object["params"] = params
        case let .notification(method, params):
            object["method"] = .string(method)
            object["params"] = params
        case let .response(id, result):
            object["id"] = id.jsonValue
            object["result"] = result
        case let .errorResponse(id, error):
            object["id"] = id?.jsonValue ?? .null
            object["error"] = .object(["code": .number(Double(error.code)), "message": .string(error.message)])
        }
        let data = try encoder.encode(JSONValue.object(object))
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// One line (with or without its trailing `\n`) as a message.
    public static func decodeLine(_ line: String) throws -> JSONRPCMessage {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              case .object(let object) = value
        else { throw ExtensionProtocolError.malformedLine }
        guard object["jsonrpc"] == .string("2.0") else { throw ExtensionProtocolError.notJSONRPC }

        // `id` absent, null, or a number/string; anything else isn't JSON-RPC.
        let id: JSONRPCID?
        switch object["id"] {
        case nil, .null?: id = nil
        case .string(let text)?: id = .string(text)
        case .number(let number)? where number.rounded() == number && abs(number) < 9_007_199_254_740_992:
            id = .number(Int(number))
        default: throw ExtensionProtocolError.notJSONRPC
        }
        let params = object["params"].flatMap { $0 == .null ? nil : $0 }

        if case .string(let method)? = object["method"] {
            if let id { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        if let error = object["error"] {
            guard case .object(let fields) = error,
                  case .number(let code)? = fields["code"],
                  case .string(let message)? = fields["message"]
            else { throw ExtensionProtocolError.notJSONRPC }
            return .errorResponse(id: id, error: JSONRPCError(code: Int(code), message: message))
        }
        if let result = object["result"], let id {
            return .response(id: id, result: result)
        }
        throw ExtensionProtocolError.notJSONRPC
    }

    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: encoder.encode(value))
        } catch let error as DecodingError {
            throw ExtensionProtocolError.payloadMismatch(String(describing: error))
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONRPCID {
    var jsonValue: JSONValue {
        switch self {
        case .number(let number): return .number(Double(number))
        case .string(let text): return .string(text)
        }
    }
}
