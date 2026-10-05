//
//  KataDaemonHTTP.swift
//  KataVaktaCore
//
//  Talking to the Kata daemon's HTTP API directly (about 11 ms a query
//  instead of ~65 ms for a `kata` process). Pure pieces: the address from
//  `kata daemon locate --json`, HTTP/1.1 request text, response parsing
//  (including chunked bodies), and what a resolve answer means. The socket
//  I/O lives in the executable.

import Foundation

public enum KataDaemonAddress: Equatable {
    case unix(path: String)
    /// A TCP or remote daemon; reached through the CLI instead.
    case other

    /// From `kata daemon locate --json`; `nil` when it isn't that shape.
    public static func parse(_ data: Data) -> KataDaemonAddress? {
        struct Located: Decodable {
            var network: String
            var address: String
        }
        guard let located = try? JSONDecoder().decode(Located.self, from: data) else { return nil }
        let prefix = "unix://"
        guard located.network == "unix", located.address.hasPrefix(prefix) else { return .other }
        return .unix(path: String(located.address.dropFirst(prefix.count)))
    }
}

public struct KataHTTPResponse: Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum KataHTTP {
    /// A complete HTTP/1.1 request; the connection closes after one response.
    public static func request(method: String, path: String, token: String?, body: Data? = nil) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: kata\r\n"
        if let token, !token.isEmpty { head += "Authorization: Bearer \(token)\r\n" }
        head += "Accept: application/json\r\nConnection: close\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    /// The status and body of a complete response (read to EOF), decoding a
    /// chunked body; `nil` when it isn't a well-formed response.
    public static func parse(_ data: Data) -> KataHTTPResponse? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.removeFirst().split(separator: " ")
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Data(data[headerEnd.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = dechunk(rest) else { return nil }
            return KataHTTPResponse(status: status, body: body)
        }
        if let length = headers["content-length"].flatMap(Int.init) {
            guard rest.count >= length else { return nil }
            return KataHTTPResponse(status: status, body: rest.prefix(length))
        }
        return KataHTTPResponse(status: status, body: rest)
    }

    private static func dechunk(_ data: Data) -> Data? {
        let crlf = Data("\r\n".utf8)
        var body = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return body } // trailers, if any, are ignored
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(index, offsetBy: size)
            body.append(data[index..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }

    public enum Resolved: Equatable {
        case project(id: Int)
        case notInitialized
        case failed(String)
    }

    public static func resolved(_ response: KataHTTPResponse) -> Resolved {
        struct Success: Decodable {
            struct Project: Decodable { var id: Int }
            var project: Project
        }
        struct Failure: Decodable {
            struct Body: Decodable {
                var code: String?
                var message: String
            }
            var error: Body
        }
        if response.status == 200, let success = try? JSONDecoder().decode(Success.self, from: response.body) {
            return .project(id: success.project.id)
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: response.body) {
            return failure.error.code == "project_not_initialized" ? .notInitialized : .failed(failure.error.message)
        }
        return .failed("The Kata daemon answered \(response.status).")
    }

    /// `{"start_path": …}` for `POST /api/v1/projects/resolve`.
    public static func resolveBody(startPath: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["start_path": startPath])) ?? Data()
    }
}
