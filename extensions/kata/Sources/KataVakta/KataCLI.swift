//
//  KataCLI.swift
//  kata-vakta
//
//  Runs the `kata` command line (found on the PATH Vakta provides) and the
//  long-running `kata events --tail` watcher.

import Foundation
import KataVaktaCore

enum KataCLI {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// Runs `kata <arguments>` and waits; stdout is drained while it runs.
    static func run(_ arguments: [String], timeout: TimeInterval = 20) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kata"] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let collected = Collected()
        let collectedErrors = Collected()
        output.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            collectedErrors.append(handle.availableData)
        }
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        collectedErrors.append(errors.fileHandleForReading.readDataToEndOfFile())
        return Result(status: process.terminationStatus, stdout: collected.data, stderr: collectedErrors.data)
    }

    static func issues(_ arguments: [String], workspace: String) -> KataOutput {
        guard let result = run(arguments + ["--json", "--limit", "0", "--workspace", workspace]) else {
            return .failed("Couldn't run kata. Is it installed and on your PATH?")
        }
        // kata writes its error envelope to stderr.
        return KataOutput.decodeIssues(result.stdout.isEmpty ? result.stderr : result.stdout)
    }

    /// Runs a mutating `kata` command; `nil` on success, else kata's message.
    static func mutate(_ arguments: [String], workspace: String) -> String? {
        guard let result = run(arguments + ["--json", "--workspace", workspace]) else {
            return "Couldn't run kata. Is it installed and on your PATH?"
        }
        guard result.status != 0 else { return nil }
        let output = result.stderr.isEmpty ? result.stdout : result.stderr
        if case .failed(let message) = KataOutput.decodeIssues(output) { return message }
        return "kata exited with status \(result.status)."
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
    }
}

/// `kata events --tail` for one project; calls `changed` (debounced) when
/// any event arrives. The replay of past events at start collapses into a
/// single call.
final class KataEventWatcher: @unchecked Sendable {
    let projectID: Int
    private let process = Process()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "kata-vakta.events")
    private var pending: DispatchWorkItem?

    init(projectID: Int, changed: @escaping @Sendable () -> Void) {
        self.projectID = projectID
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kata", "events", "--tail", "--json", "--project-id", String(projectID)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, !handle.availableData.isEmpty else { return }
            self.queue.async {
                self.pending?.cancel()
                let work = DispatchWorkItem(block: changed)
                self.pending = work
                self.queue.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
    }

    func start() {
        try? process.run()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
