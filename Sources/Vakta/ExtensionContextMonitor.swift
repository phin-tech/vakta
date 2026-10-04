//
//  ExtensionContextMonitor.swift
//  Vakta
//
//  Keeps the Extension host's contexts current: snapshots every Session on
//  the main actor when Sessions, selection or workspaces change (and on the
//  file sidebar's refresh signal, which fires as the focused pane's
//  directory may have moved), gathers working directories and git state off
//  the main actor, and drops results superseded by a newer snapshot.

import AppKit
import Combine
import Foundation
import VaktaExtensionKit

@MainActor
final class ExtensionContextMonitor {
    private let sessionStore: SessionStore
    private let host: ExtensionHost
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = 0
    private var periodic: Timer?

    init(sessionStore: SessionStore, host: ExtensionHost) {
        self.sessionStore = sessionStore
        self.host = host

        let changes: [AnyPublisher<Void, Never>] = [
            sessionStore.$sessions.map { _ in () }.eraseToAnyPublisher(),
            sessionStore.$selectedID.map { _ in () }.eraseToAnyPublisher(),
            sessionStore.$workspaces.map { _ in () }.eraseToAnyPublisher(),
            sessionStore.fileSidebarRefreshed.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            // Just enough to coalesce one switch's burst of publishes.
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)

        // A `cd` inside a multiplexer pane produces no event Vakta sees, so
        // re-gather occasionally while any Extension is running.
        periodic = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.host.phases.values.contains(.running) else { return }
                self.refresh()
            }
        }
    }

    deinit {
        periodic?.invalidate()
    }

    // MARK: - Input hint

    /// A key or click in the focused terminal may have switched its pane,
    /// tab or workspace (Vakta sees no event for that from tmux). Shortly
    /// after input pauses, re-gather just the focused Session -- regardless
    /// of whether the file panel is open, and with no minimum interval.
    private let inputDebouncer = WorkspaceRefreshDebouncer(debounceInterval: 0.1, minInterval: 0)
    private var inputMonitor: Any?
    private var pendingFocusedRefresh: DispatchWorkItem?

    /// Installs the non-consuming input monitor (never swallows an event).
    func install() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { @MainActor [weak self] event in
            self?.inputArrived()
            return event
        }
    }

    private func inputArrived() {
        guard host.phases.values.contains(.running),
              let id = sessionStore.selectedID,
              sessionStore.sessions.first(where: { $0.id == id })?.viewState.isFocused == true
        else { return }
        scheduleFocusedRefresh()
    }

    /// Re-gathers the focused Session soon (coalescing a burst), keeping the
    /// others as last known. Also the entry point for multiplexer focus events.
    func scheduleFocusedRefresh() {
        let now = Date()
        let fireDate = inputDebouncer.scheduledFireDate(now: now, lastFireDate: nil)
        pendingFocusedRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFocused() }
        pendingFocusedRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireDate.timeIntervalSince(now)), execute: work)
    }

    private func refreshFocused() {
        generation += 1
        let current = generation
        let inputs = snapshot()
        guard let focused = inputs.first(where: \.focused) else { return }
        let path = sessionStore.resolvedPATH
        Task { [weak self] in
            let fresh = await Self.gather(focused, path: path)
            guard let self, self.generation == current else { return }
            self.known[focused.sessionID] = fresh
            self.host.updateContexts(ExtensionContextPlanner.focusedFirst(inputs: inputs, fresh: fresh, previous: self.known))
        }
    }

    /// Last gathered context per Session, for the quick first snapshot.
    private var known: [UUID: ExtensionContext] = [:]

    /// Two passes: the focused Session first (what the panel shows), sent
    /// at once with the others as last known; then every Session in
    /// parallel. A newer refresh supersedes both.
    func refresh() {
        generation += 1
        let current = generation
        let inputs = snapshot()
        let path = sessionStore.resolvedPATH
        Task { [weak self] in
            if let focused = inputs.first(where: \.focused) {
                let fresh = await Self.gather(focused, path: path)
                guard let self, self.generation == current else { return }
                self.known[focused.sessionID] = fresh
                self.host.updateContexts(ExtensionContextPlanner.focusedFirst(inputs: inputs, fresh: fresh, previous: self.known))
            }
            let includingPanes = self?.host.wantsPanes ?? false
            let contexts = await Self.gather(inputs, path: path, includingPanes: includingPanes)
            guard let self, self.generation == current else { return }
            self.known = Dictionary(uniqueKeysWithValues: zip(inputs.map(\.sessionID), contexts))
            self.host.updateContexts(contexts)
        }
    }

    /// Nonisolated, so the blocking queries run off the main actor.
    private nonisolated static func gather(
        _ inputs: [ExtensionSessionInput], path: String, includingPanes: Bool
    ) async -> [ExtensionContext] {
        ExtensionContextGatherer.gather(inputs, path: path, includingPanes: includingPanes)
    }

    private nonisolated static func gather(_ input: ExtensionSessionInput, path: String) async -> ExtensionContext {
        ExtensionContextGatherer.gather(input, path: path)
    }

    private func snapshot() -> [ExtensionSessionInput] {
        sessionStore.sessions.map { session in
            let target: MultiplexerTarget?
            if case .multiplexer(let resolved) = LaunchTargetResolver.resolve(session.profile) {
                target = resolved
            } else {
                target = nil
            }
            return ExtensionSessionInput(
                sessionID: session.id,
                target: target,
                sessionName: session.sessionName,
                terminalReportedWorkingDirectory: session.viewState.workingDirectory,
                profileWorkingDirectory: session.profile.workingDirectory,
                focusedWorkspace: sessionStore.workspaces[session.id]?.first(where: \.focused),
                focused: session.id == sessionStore.selectedID,
                workspaces: sessionStore.workspaces[session.id] ?? []
            )
        }
    }
}
