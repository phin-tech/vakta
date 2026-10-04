//
//  ExtensionHost.swift
//  Vakta
//
//  Runs every ready Linked Extension: one supervised child process each,
//  started and stopped as registry entries become ready or not, sent the
//  current Extension Contexts after each handshake and on every change. The
//  lifecycle decisions are `ExtensionSupervisor`'s; this type executes them.

import Combine
import Foundation
import VaktaExtensionKit

struct CallbackFailure: Error, Equatable {
    let message: String
}

enum ExtensionRequestError: Error, Equatable {
    case notRunning
    case timedOut
    case rejected(JSONRPCError)
    /// The process exited or was stopped before answering.
    case interrupted
}

@MainActor
final class ExtensionHost: ObservableObject {
    /// Keyed by manifest id.
    @Published private(set) var phases: [String: ExtensionSupervisor.Phase] = [:]

    /// The focused Session's Extension Context, as last sent.
    @Published private(set) var focusedContext: ExtensionContext?

    /// Messages from running Extensions for features to route (view updates,
    /// status items, badges). `log` notifications are written to the log here.
    let messages = PassthroughSubject<(extensionID: String, message: JSONRPCMessage), Never>()
    /// An Extension stopped running for any reason; remove its Contributions.
    let stopped = PassthroughSubject<String, Never>()
    /// An Extension finished its handshake.
    let ready = PassthroughSubject<String, Never>()

    private let registry: ExtensionRegistryStore
    private let supportRoot: URL
    private let hostVersion: String
    private let policy: ExtensionSupervisor.Policy
    private let environment: @MainActor () -> [String: String]
    private let loginEnvironment: @MainActor () -> [String: String]
    private var runtimes: [String: ExtensionRuntime] = [:]
    /// Replaced runtimes kept alive until their shutdown finishes, so their
    /// kill timer still fires.
    private var retiring: [ObjectIdentifier: ExtensionRuntime] = [:]
    private var contexts: [ExtensionContext] = []
    private var subscription: AnyCancellable?

    init(
        registry: ExtensionRegistryStore,
        supportRoot: URL,
        hostVersion: String,
        policy: ExtensionSupervisor.Policy = .init(),
        environment: @escaping @MainActor () -> [String: String],
        loginEnvironment: @escaping @MainActor () -> [String: String] = { [:] }
    ) {
        self.loginEnvironment = loginEnvironment
        self.registry = registry
        self.supportRoot = supportRoot
        self.hostVersion = hostVersion
        self.policy = policy
        self.environment = environment
        subscription = registry.$entries.sink { [weak self] entries in
            // `sink` runs before `entries` is assigned; reconcile on the value.
            self?.reconcile(entries)
        }
    }

    func updateContexts(_ contexts: [ExtensionContext]) {
        guard contexts != self.contexts else { return }
        self.contexts = contexts
        let focused = contexts.first(where: \.focused)
        if focused != focusedContext { focusedContext = focused }
        for runtime in runtimes.values where runtime.phase == .running {
            runtime.sendContexts(ExtensionContextPlanner.contexts(contexts, includingPanes: runtime.wantsPanes))
        }
    }

    func restart(_ extensionID: String) {
        runtimes[extensionID]?.restart()
    }

    /// Whether any running Extension asked for Pane Contexts (so they're
    /// worth gathering).
    var wantsPanes: Bool {
        runtimes.values.contains { $0.wantsPanes && $0.isActive }
    }

    /// The login-shell environment changed (it finished resolving): restart
    /// every Extension that receives variables from it, with the new values.
    func loginEnvironmentChanged() {
        for (id, runtime) in runtimes where !runtime.declaredEnvironment.isEmpty {
            retire(runtime)
            runtimes[id] = nil
        }
        reconcile(registry.entries)
    }

    /// Asks every Extension to shut down (app quit).
    func stopAll() {
        for runtime in runtimes.values { runtime.stop() }
        for runtime in retiring.values { runtime.stop() }
    }

    func logURL(for extensionID: String) -> URL {
        supportRoot.appendingPathComponent("extension-logs", isDirectory: true)
            .appendingPathComponent("\(extensionID).log")
    }

    func request(
        _ extensionID: String, method: String, params: JSONValue?, timeout: TimeInterval = 10
    ) async throws -> JSONValue {
        guard let runtime = runtimes[extensionID], runtime.phase == .running else { throw ExtensionRequestError.notRunning }
        return try await runtime.request(method: method, params: params, timeout: timeout)
    }

    /// Sends a button's Callback and returns the Effects, or a short,
    /// user-presentable reason it failed.
    func sendCallback(
        _ extensionID: String, view: String, button: ViewButton, form: [String: JSONValue]?, timeout: TimeInterval
    ) async -> Result<[Effect], CallbackFailure> {
        do {
            let params = CallbackParams(view: view, callback: button.callback, payload: button.payload, form: form)
            let result = try await request(extensionID, method: ProtocolMethod.callback, params: try ExtensionProtocolCodec.encode(params), timeout: timeout)
            return .success(try ExtensionProtocolCodec.decode(CallbackResult.self, from: result).effects)
        } catch ExtensionRequestError.rejected(let error) {
            return .failure(CallbackFailure(message: error.message))
        } catch ExtensionRequestError.timedOut {
            return .failure(CallbackFailure(message: "The extension didn't answer in time."))
        } catch ExtensionRequestError.notRunning, ExtensionRequestError.interrupted {
            return .failure(CallbackFailure(message: "The extension isn't running."))
        } catch {
            return .failure(CallbackFailure(message: "The extension's answer couldn't be read."))
        }
    }

    func notify(_ extensionID: String, method: String, params: JSONValue?) {
        guard let runtime = runtimes[extensionID], runtime.phase == .running else { return }
        runtime.send(.notification(method: method, params: params))
    }

    // MARK: - Private

    /// Starts runtimes for ready entries, stops the rest, and restarts one
    /// whose approval changed (a re-approved manifest or executable).
    private func reconcile(_ entries: [ExtensionEntry]) {
        var wanted: [String: (ExtensionEntry, ExtensionManifest)] = [:]
        for entry in entries where entry.status == .ready {
            if let manifest = entry.manifest { wanted[manifest.id] = (entry, manifest) }
        }
        for (id, runtime) in runtimes {
            guard let (entry, _) = wanted[id], entry.record.approved == runtime.approval,
                  entry.record.directory == runtime.directory.path
            else {
                runtime.stop()
                continue
            }
        }
        for (id, (entry, manifest)) in wanted {
            if let existing = runtimes[id] {
                if existing.approval == entry.record.approved, existing.directory.path == entry.record.directory,
                   existing.isActive {
                    continue
                }
                retire(existing)
            }
            guard let executable = manifest.executableURL(in: entry.directoryURL) else { continue }
            let runtime = ExtensionRuntime(
                id: id,
                directory: entry.directoryURL,
                executable: executable,
                arguments: Array(manifest.command.dropFirst()),
                approval: entry.record.approved,
                declaredEnvironment: manifest.environment,
                wantsPanes: manifest.wantsPanes,
                environment: childEnvironment(for: id, directory: entry.directoryURL, declared: manifest.environment),
                log: ExtensionLog(url: logURL(for: id)),
                supervisor: ExtensionSupervisor(policy: policy, initialize: initializeParams)
            )
            runtime.onPhase = { [weak self, weak runtime] phase in
                guard let self, let runtime, self.runtimes[id] === runtime else { return }
                self.phases[id] = phase
                if phase == .running {
                    runtime.sendContexts(ExtensionContextPlanner.contexts(self.contexts, includingPanes: runtime.wantsPanes))
                    self.ready.send(id)
                } else {
                    self.stopped.send(id)
                }
            }
            runtime.onMessage = { [weak self, weak runtime] message in
                guard let self, let runtime, self.runtimes[id] === runtime else { return }
                self.messages.send((extensionID: id, message: message))
            }
            runtimes[id] = runtime
            runtime.start()
        }
    }

    private func retire(_ runtime: ExtensionRuntime) {
        runtime.stop()
        guard runtime.isActive || runtime.phase == .stopping else { return }
        let key = ObjectIdentifier(runtime)
        retiring[key] = runtime
        runtime.onMessage = nil
        runtime.onPhase = { [weak self] phase in
            if phase == .stopped { self?.retiring[key] = nil }
        }
    }

    private var initializeParams: InitializeParams {
        InitializeParams(
            apiVersion: vaktaExtensionAPIVersion,
            host: HostInfo(name: "Vakta", version: hostVersion),
            capabilities: HostCapabilities(viewKinds: Self.supportedViewKinds, effects: Self.supportedEffects)
        )
    }

    /// What this host draws and carries out; grows as Contributions land.
    static let supportedViewKinds: [String] = ["list", "detail", "form"]
    static let supportedEffects: [String] = [
        "refresh", "replace", "push", "pop", "toast", "notify", "open_url", "open_pane", "open_session",
    ]

    /// Built from scratch: Vakta's own environment is never passed through
    /// or mutated. Login-shell variables the manifest declares come first;
    /// Vakta's own (PATH, HOME, VAKTA_*) always win.
    private func childEnvironment(for id: String, directory: URL, declared: [String]) -> [String: String] {
        let configDirectory = supportRoot.appendingPathComponent("extension-data", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        var values = ExtensionEnvironment.passthrough(declared, from: loginEnvironment())
            .merging(environment(), uniquingKeysWith: { _, vakta in vakta })
        values["VAKTA_EXTENSION_ID"] = id
        values["VAKTA_EXTENSION_ROOT"] = directory.path
        values["VAKTA_EXTENSION_CONFIG_DIR"] = configDirectory.path
        values["VAKTA_EXTENSION_API"] = String(vaktaExtensionAPIVersion)
        return values
    }
}

/// One Extension's process plus its supervisor: executes the supervisor's
/// effects, correlates request ids, and ignores events from a previous
/// process after a restart.
@MainActor
final class ExtensionRuntime {
    let id: String
    let directory: URL
    let approval: TrustFingerprint?
    let declaredEnvironment: [String]
    let wantsPanes: Bool
    var onPhase: ((ExtensionSupervisor.Phase) -> Void)?
    var onMessage: ((JSONRPCMessage) -> Void)?

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let log: ExtensionLog
    private var supervisor: ExtensionSupervisor
    private var process: ExtensionProcess?
    private var generation = 0
    private var timerTokens: [ExtensionSupervisor.Timer: Int] = [:]
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    var phase: ExtensionSupervisor.Phase { supervisor.phase }

    /// Running, starting, or recovering: not stopped or stopping.
    var isActive: Bool {
        switch supervisor.phase {
        case .stopped, .stopping: return false
        default: return true
        }
    }

    init(
        id: String, directory: URL, executable: URL, arguments: [String], approval: TrustFingerprint?,
        declaredEnvironment: [String] = [], wantsPanes: Bool = false, environment: [String: String], log: ExtensionLog,
        supervisor: ExtensionSupervisor
    ) {
        self.declaredEnvironment = declaredEnvironment
        self.wantsPanes = wantsPanes
        self.id = id
        self.directory = directory
        self.executable = executable
        self.arguments = arguments
        self.approval = approval
        self.environment = environment
        self.log = log
        self.supervisor = supervisor
    }

    func start() { handle(.start) }
    func stop() { handle(.stop) }
    func restart() { handle(.restart) }

    func send(_ message: JSONRPCMessage) {
        guard let line = try? ExtensionProtocolCodec.encodeLine(message) else { return }
        process?.send(line)
    }

    func sendContexts(_ contexts: [ExtensionContext]) {
        guard let params = try? ExtensionProtocolCodec.encode(ContextsChangedParams(contexts: contexts)) else { return }
        send(.notification(method: ProtocolMethod.contextsChanged, params: params))
    }

    func request(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let id = supervisor.makeRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(.request(id: .number(id), method: method, params: params))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                self.send(.notification(method: ProtocolMethod.cancel, params: .object(["id": .number(Double(id))])))
                waiting.resume(throwing: ExtensionRequestError.timedOut)
            }
        }
    }

    // MARK: - Effects

    private func handle(_ event: ExtensionSupervisor.Event) {
        let before = supervisor.phase
        let effects = supervisor.handle(event)
        for effect in effects { perform(effect) }
        if supervisor.phase != before {
            if supervisor.phase != .running { failPending(.interrupted) }
            onPhase?(supervisor.phase)
        }
    }

    private func perform(_ effect: ExtensionSupervisor.Effect) {
        switch effect {
        case .spawn:
            spawn()
        case .send(let message):
            send(message)
        case .kill:
            process?.kill()
        case let .schedule(timer, delay):
            let token = (timerTokens[timer] ?? 0) + 1
            timerTokens[timer] = token
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.timerTokens[timer] == token else { return }
                self.handle(.timerFired(timer, at: Date()))
            }
        case .becameReady:
            log.append("[vakta] \(id) ready")
        case .deliver(let message):
            deliver(message)
        }
    }

    private func spawn() {
        generation += 1
        let current = generation
        let child = ExtensionProcess(
            executable: executable, arguments: arguments, directory: directory, environment: environment, log: log
        )
        process = child
        do {
            try child.start(
                onLine: { [weak self] line in
                    MainActor.assumeIsolated { self?.received(line, generation: current) }
                },
                onExit: { [weak self] status in
                    MainActor.assumeIsolated { self?.exited(status, generation: current) }
                }
            )
            log.append("[vakta] started \(executable.path) pid=\(child.processIdentifier)")
            handle(.spawned)
        } catch {
            log.append("[vakta] couldn't start \(executable.path): \(error.localizedDescription)")
            process = nil
            handle(.spawnFailed)
        }
    }

    private func received(_ line: String, generation: Int) {
        guard generation == self.generation else { return }
        do {
            handle(.received(try ExtensionProtocolCodec.decodeLine(line)))
        } catch {
            log.append("[vakta] ignored a line that isn't JSON-RPC: \(line.prefix(200))")
        }
    }

    private func exited(_ status: Int32, generation: Int) {
        guard generation == self.generation else { return }
        log.append("[vakta] exited with status \(status)")
        process = nil
        handle(.exited(code: status, at: Date()))
    }

    private func deliver(_ message: JSONRPCMessage) {
        switch message {
        case let .response(.number(id), result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case let .errorResponse(.number(id)?, error):
            pending.removeValue(forKey: id)?.resume(throwing: ExtensionRequestError.rejected(error))
        case .response, .errorResponse:
            break
        case let .notification(method, params) where method == ProtocolMethod.log:
            if let entry = params.flatMap({ try? ExtensionProtocolCodec.decode(LogParams.self, from: $0) }) {
                log.append("[\(entry.level.rawValue)] \(entry.message)")
            }
        case .notification, .request:
            onMessage?(message)
        }
    }

    private func failPending(_ error: ExtensionRequestError) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
