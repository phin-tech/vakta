//
//  ExtensionProcess.swift
//  Vakta
//
//  One Extension child process: argv run in the Extension directory with an
//  explicit environment, newline-delimited messages on stdin/stdout, stderr
//  appended to the Extension log. Callbacks arrive on the main queue.

import Foundation

/// Append-only per-Extension log. Writes are serialized on a private queue
/// (stderr arrives on a background thread). Started fresh once it grows
/// past `maxBytes`.
final class ExtensionLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "tech.phin.vakta.extension-log")
    private let maxBytes: UInt64

    init(url: URL, maxBytes: UInt64 = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ text: String) {
        let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        queue.async { [url, maxBytes] in
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size > maxBytes || !manager.fileExists(atPath: url.path) {
                try? data.write(to: url, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

/// Splits a byte stream into lines. Pure value type so it's testable; a line
/// longer than `maxLineBytes` is dropped rather than buffered without bound.
struct LineSplitter {
    let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false

    init(maxLineBytes: Int = 8 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// Returns complete lines (without `\n`) and how many oversize lines
    /// were dropped.
    mutating func append(_ chunk: Data) -> (lines: [String], dropped: Int) {
        var lines: [String] = []
        var dropped = 0
        for byte in chunk {
            if byte == 0x0A {
                if discarding {
                    discarding = false
                } else {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                }
                buffer.removeAll(keepingCapacity: true)
            } else if !discarding {
                buffer.append(byte)
                if buffer.count > maxLineBytes {
                    buffer.removeAll()
                    discarding = true
                    dropped += 1
                }
            }
        }
        return (lines, dropped)
    }
}

final class ExtensionProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let log: ExtensionLog
    private let lock = NSLock()
    private var splitter = LineSplitter()

    var processIdentifier: Int32 { process.processIdentifier }

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], log: ExtensionLog) {
        self.log = log
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    /// `onLine` and `onExit` run on the main queue.
    func start(onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        // Writing to a pipe whose reader is gone must fail with EPIPE, not
        // deliver SIGPIPE to Vakta.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            let (lines, dropped) = self.splitter.append(chunk)
            self.lock.unlock()
            if dropped > 0 { self.log.append("[vakta] dropped \(dropped) oversize line(s) from stdout") }
            for line in lines where !line.isEmpty {
                DispatchQueue.main.async { onLine(line) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [log] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            log.append(String(decoding: chunk, as: UTF8.self))
        }
        process.terminationHandler = { [output, errors] process in
            let status = process.terminationStatus
            // Let the last stdout chunk drain before reporting the exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { onExit(status) }
            }
        }
        try process.run()
    }

    func send(_ line: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
    }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
