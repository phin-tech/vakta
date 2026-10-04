//
//  Tools.swift
//  vakta-github
//
//  Running git and gh (found on the PATH Vakta provides) and HTTPS GraphQL.

import Foundation
import GitHubCore

enum Tool {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// Runs `argv` through /usr/bin/env, draining both pipes; nil when it
    /// can't start. `stdin` is written then closed.
    static func run(_ argv: [String], stdin: Data? = nil, timeout: TimeInterval = 30) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let lock = NSLock()
        var stdout = Data(), stderr = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); stdout.append(chunk); lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); stderr.append(chunk); lock.unlock()
        }
        do { try process.run() } catch { return nil }
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline { process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        stdout.append(out.fileHandleForReading.readDataToEndOfFile())
        stderr.append(err.fileHandleForReading.readDataToEndOfFile())
        lock.unlock()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// GitHub GraphQL: HTTPS with a token (GH_TOKEN, GITHUB_TOKEN, or
/// `gh auth token`), falling back to `gh api graphql` with the same query.
final class GitHubAPI: @unchecked Sendable {
    private var tokens: [String: String] = [:]

    func fetch(_ query: PullRequestQuery, host: String) -> Result<PullRequestResult, PullRequestResponseError> {
        if let current = token(for: host, refresh: false) {
            switch post(query, host: host, token: current) {
            case .failure(.unauthorized):
                if let fresh = token(for: host, refresh: true), fresh != current,
                   case .success(let result) = post(query, host: host, token: fresh) {
                    return .success(result)
                }
            case .success(let result):
                return .success(result)
            case .failure(.rateLimited(let resetsAt)):
                return .failure(.rateLimited(resetsAt: resetsAt))
            case .failure:
                break
            }
        }
        return viaCLI(query, host: host)
    }

    private func token(for host: String, refresh: Bool) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if host == "github.com", let token = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"], !token.isEmpty { return token }
        if !refresh, let cached = tokens[host] { return cached }
        guard let output = Tool.run(["gh", "auth", "token", "--hostname", host], timeout: 10), output.status == 0 else { return nil }
        let token = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        tokens[host] = token
        return token
    }

    private func post(_ query: PullRequestQuery, host: String, token: String) -> Result<PullRequestResult, PullRequestResponseError> {
        let endpoint = host == "github.com" ? "https://api.github.com/graphql" : "https://\(host)/api/graphql"
        guard let url = URL(string: endpoint),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query.text])
        else { return .failure(.malformed) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vakta-github", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<PullRequestResult, PullRequestResponseError> = .failure(.malformed)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { outcome = .failure(.unauthorized); return }
            guard let data else { return }
            outcome = PullRequestResponse.parse(data, for: query)
        }.resume()
        done.wait()
        return outcome
    }

    private func viaCLI(_ query: PullRequestQuery, host: String) -> Result<PullRequestResult, PullRequestResponseError> {
        guard let output = Tool.run(["gh", "api", "graphql", "--hostname", host, "-f", "query=\(query.text)"], timeout: 30) else {
            return .failure(.graphQL("Couldn't run gh. Is it installed and signed in?"))
        }
        if output.stdout.isEmpty {
            return .failure(.graphQL(String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return PullRequestResponse.parse(output.stdout, for: query)
    }
}
