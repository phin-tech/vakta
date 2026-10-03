//
//  KataDaemonClient.swift
//  kata-vakta
//
//  Reads from the Kata daemon over its Unix socket (HTTP/1.1, one request
//  per connection). The address comes from `kata daemon locate --json`,
//  looked up once and again after a connection failure; the bearer token is
//  KATA_AUTH_TOKEN (the manifest's `KATA_*` passthrough). Callers fall back
//  to the `kata` CLI whenever this returns nil.

import Foundation
import KataVaktaCore

final class KataDaemonClient: @unchecked Sendable {
    private let lock = NSLock()
    private var address: KataDaemonAddress?
    private let token = ProcessInfo.processInfo.environment["KATA_AUTH_TOKEN"]

    /// Open and ready issues for `workspace`, or nil to use the CLI instead.
    func query(_ workspace: String) -> KataQueryCache.Value? {
        guard let resolve = send("POST", "/api/v1/projects/resolve", body: KataHTTP.resolveBody(startPath: workspace)) else { return nil }
        switch KataHTTP.resolved(resolve) {
        case .notInitialized:
            return .notInitialized
        case .failed:
            return nil
        case .project(let id):
            var ready: KataHTTPResponse?
            let readyDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                ready = self.send("GET", "/api/v1/projects/\(id)/ready?limit=0")
                readyDone.signal()
            }
            let open = send("GET", "/api/v1/projects/\(id)/issues?status=open&limit=0")
            readyDone.wait()
            guard let open, open.status == 200, case .issues(let issues) = KataOutput.decodeIssues(open.body) else { return nil }
            var readyIDs: Set<String> = []
            if let ready, ready.status == 200, case .issues(let readyIssues) = KataOutput.decodeIssues(ready.body) {
                readyIDs = Set(readyIssues.map(\.shortID))
            }
            return .loaded(open: issues, readyIDs: readyIDs)
        }
    }

    /// Looks the daemon up ahead of the first query (off the caller's queue).
    func warm() {
        DispatchQueue.global(qos: .utility).async { _ = self.socketPath() }
    }

    private func socketPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if address == nil, let located = KataCLI.run(["daemon", "locate", "--json"], timeout: 5) {
            address = KataDaemonAddress.parse(located.stdout)
        }
        if case .unix(let path)? = address { return path }
        return nil
    }

    private func forgetAddress() {
        lock.lock()
        address = nil
        lock.unlock()
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) -> KataHTTPResponse? {
        guard let socket = socketPath() else { return nil }
        let request = KataHTTP.request(method: method, path: path, token: token, body: body)
        guard let raw = Self.exchange(request, socketPath: socket, timeout: 5), let response = KataHTTP.parse(raw) else {
            forgetAddress()
            return nil
        }
        return response
    }

    /// Writes `request` to the socket and reads until the daemon closes it.
    private static func exchange(_ request: Data, socketPath: String, timeout: TimeInterval) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var sent = 0
        let total = request.count
        while sent < total {
            let written = request.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress!.advanced(by: sent), total - sent)
            }
            guard written > 0 else { return nil }
            sent += written
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { return nil }
            response.append(contentsOf: buffer[0..<count])
            if response.count > 32 * 1024 * 1024 { return nil }
        }
        return response
    }
}
