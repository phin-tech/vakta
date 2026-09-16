//
//  BoundedProcessRunner.swift
//  Vakta
//
//  One shared subprocess adapter for every short-lived helper command Vakta
//  spawns (session discovery, agent-status polling, login-shell PATH
//  resolution). Replaces two near-duplicate implementations
//  (`ProcessRunner.run`, `ShellEnvironment.loginShellPATH`) that both waited
//  on a termination semaphore BEFORE reading stdout: a child that writes more
//  than one pipe buffer (64KB on macOS) blocks on its own `write()` once the
//  pipe fills, so it never terminates, so the semaphore never fires, so the
//  caller sits out the full timeout and returns nothing -- even though the
//  child would have succeeded if anyone had been draining its output. This
//  drains continuously while the process runs instead.

import Foundation

/// The raw outcome of running a helper process, before UTF-8 decoding --
/// kept separate so interpreting it is a pure function, testable without
/// executing anything (see `ProcessResultInterpreter`).
struct ProcessRawResult: Equatable {
    var launchFailed: Bool = false
    var exitCode: Int32?
    var stdout: Data = Data()
    var timedOut: Bool = false
    var cancelled: Bool = false
}

/// A helper process's outcome, distinguishing every documented failure mode
/// rather than collapsing them all to "nil."
enum ProcessResult: Equatable {
    case success(String)
    case launchFailed
    case nonZeroExit(Int32)
    case invalidUTF8
    case timedOut
    case cancelled
}

enum ProcessResultInterpreter {
    /// Pure: `raw`'s fields are mutually exclusive by construction
    /// (`BoundedProcessRunner` sets at most one of `launchFailed`/
    /// `cancelled`/`timedOut`), checked in that priority order.
    static func interpret(_ raw: ProcessRawResult) -> ProcessResult {
        if raw.launchFailed { return .launchFailed }
        if raw.cancelled { return .cancelled }
        if raw.timedOut { return .timedOut }
        guard let exitCode = raw.exitCode, exitCode == 0 else {
            return .nonZeroExit(raw.exitCode ?? -1)
        }
        guard let string = String(data: raw.stdout, encoding: .utf8) else { return .invalidUTF8 }
        return .success(string)
    }
}

enum BoundedProcessRunner {
    /// Stdout beyond this is discarded (but still drained, so the child
    /// never blocks on a full pipe) -- bounds memory against a runaway or
    /// malicious child. Generous for the CLI table/JSON output every caller
    /// here actually expects.
    static let maxOutputBytes = 4 * 1024 * 1024

    /// How long a terminated (`SIGTERM`) child is given to actually exit
    /// before escalating to `SIGKILL` -- bounds cleanup for a child that
    /// ignores termination.
    static let terminationGracePeriod: TimeInterval = 1

    /// Runs `executable` with `arguments`/`environment`, draining stdout
    /// continuously on a dedicated dispatch source (never letting the pipe
    /// fill and block the child) up to `maxOutputBytes`, bounded by
    /// `timeout`. `isCancelled`, polled cooperatively, lets a caller abort
    /// early. Blocks the calling thread until the process exits, is
    /// terminated for a timeout/cancellation, or fails to launch -- callers
    /// run this off whatever thread must not block (see `ProcessRunner`,
    /// `ShellEnvironment`).
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maxOutputBytes: Int = maxOutputBytes,
        isCancelled: @escaping () -> Bool = { false }
    ) -> ProcessResult {
        ProcessResultInterpreter.interpret(runRaw(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            isCancelled: isCancelled
        ))
    }

    static func runRaw(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maxOutputBytes: Int = maxOutputBytes,
        isCancelled: @escaping () -> Bool = { false }
    ) -> ProcessRawResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(maxBytes: maxOutputBytes)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessRawResult(launchFailed: true)
        }

        /// Foundation's exit notification (a kqueue proc event) and the
        /// pipe's last readable event (a separate kqueue) have no ordering
        /// guarantee -- if exit is observed first, nil-ing the handler
        /// immediately can drop bytes still sitting in the pipe. A BOUNDED
        /// non-blocking drain (not `readDataToEndOfFile()`, which blocks
        /// until true EOF) catches that last chunk: our direct child dying
        /// does NOT guarantee EOF on the pipe if it forked its own child
        /// that inherited the write end and is still running (e.g. a shell
        /// script's last command backgrounding or exec'ing something) --
        /// that grandchild is not ours to track, and `readDataToEndOfFile()`
        /// would then block until IT exits, unbounded.
        func finish(exitCode: Int32?, timedOut: Bool, cancelled: Bool) -> ProcessRawResult {
            outPipe.fileHandleForReading.readabilityHandler = nil
            drainNonBlocking(outPipe.fileHandleForReading, into: collector, for: 0.2)
            return ProcessRawResult(exitCode: exitCode, stdout: collector.data, timedOut: timedOut, cancelled: cancelled)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if isCancelled() {
                terminateAndReap(process)
                return finish(exitCode: process.terminationStatus, timedOut: false, cancelled: true)
            }
            if Date() >= deadline {
                terminateAndReap(process)
                return finish(exitCode: process.terminationStatus, timedOut: true, cancelled: false)
            }
            usleep(20_000)
        }
        return finish(exitCode: process.terminationStatus, timedOut: false, cancelled: false)
    }

    /// `terminate()` sends `SIGTERM`; a child that ignores it would
    /// otherwise leave cleanup unbounded, so after `terminationGracePeriod`
    /// this escalates to `SIGKILL` and reaps the process either way.
    private static func terminateAndReap(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Reads whatever is immediately available from `handle` in a loop,
    /// without ever blocking on the fd, for up to `duration` -- catches a
    /// final chunk still sitting in the pipe without risking a hang if the
    /// write end is (or becomes) held open by something other than the
    /// process we're actually waiting on (see `finish` above). Real EOF
    /// (`read` returning `0`) ends the loop early.
    private static func drainNonBlocking(_ handle: FileHandle, into collector: OutputCollector, for duration: TimeInterval) {
        let fd = handle.fileDescriptor
        let existingFlags = fcntl(fd, F_GETFL, 0)
        guard existingFlags != -1 else { return }
        _ = fcntl(fd, F_SETFL, existingFlags | O_NONBLOCK)

        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let bytesRead = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if bytesRead > 0 {
                collector.append(Data(buffer[0..<bytesRead]))
            } else if bytesRead == 0 {
                return // real EOF
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(5_000)
            } else {
                return // a real read error; nothing more to collect
            }
        }
    }

    /// A small thread-safe accumulator for `readabilityHandler`, which
    /// Foundation calls on its own dispatch I/O queue -- not necessarily the
    /// thread that started the process.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private let maxBytes: Int

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard storage.count < maxBytes else { return }
            storage.append(chunk.prefix(maxBytes - storage.count))
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
