//
//  WorkspaceRefreshTrigger.swift
//  Vakta
//
//  A key or click sent into a workspace-capable session's terminal (tmux
//  prefix+n, a herdr TUI switch, ...) is the only local signal Vakta has
//  that the active workspace/window might have changed underneath it: tmux
//  has no event stream to subscribe to (docs/multiplexer-backends.md), and
//  herdr's own `workspace.*` events are unverified (docs/herdr-events-plan.md's
//  Follow-ups). `WorkspaceRefreshGate` decides whether a given event is even
//  a candidate; `WorkspaceRefreshDebouncer` decides *when* a candidate
//  actually fires a fetch, collapsing a typing/click burst into one call
//  without starving updates during a long burst.
//
//  Known gap: a switch driven from outside Vakta -- another attached tmux
//  client, a script calling `select-window` -- isn't caught by this. tmux
//  control mode (`-C`) is the documented future event path if that matters.

import AppKit
import Foundation

/// Whether a passthrough input event is worth considering as a workspace-
/// switch signal. Pure AND of independent conditions, mirroring
/// `WorkspaceFetchPlanner`'s style.
enum WorkspaceRefreshGate {
    static func shouldTrigger(
        eventIsKeyDownOrLeftMouseDown: Bool,
        sessionIsFocused: Bool,
        supportsWorkspaces: Bool,
        showWorkspaces: Bool
    ) -> Bool {
        eventIsKeyDownOrLeftMouseDown && sessionIsFocused && supportsWorkspaces && showWorkspaces
    }
}

/// Trailing debounce with a minimum-interval floor: a burst of candidate
/// events collapses to one fetch `debounceInterval` after the burst's last
/// event, but never fires sooner than `minInterval` after the previous
/// actual fire -- so a long burst still gets periodic updates rather than
/// being pushed out indefinitely.
struct WorkspaceRefreshDebouncer {
    let debounceInterval: TimeInterval
    let minInterval: TimeInterval

    /// The date at which a pending fetch triggered by an event arriving at
    /// `now` should fire, given `lastFireDate` (nil if nothing has fired
    /// yet this session).
    func scheduledFireDate(now: Date, lastFireDate: Date?) -> Date {
        let debounced = now.addingTimeInterval(debounceInterval)
        guard let lastFireDate else { return debounced }
        let earliestAllowed = lastFireDate.addingTimeInterval(minInterval)
        return max(debounced, earliestAllowed)
    }
}

/// Imperative shell: a non-consuming local `NSEvent` monitor (same mechanism
/// as `KeybindingMatcher`, watching a different event set) that re-fetches a
/// session's workspaces shortly after a key or click reaches its terminal.
/// Checklist-verified only (real AppKit event monitor, real `SessionStore`) --
/// same rationale as `SessionStore`'s existing 0%-coverage note in
/// docs/testing.md.
@MainActor
final class WorkspaceRefreshMonitor {
    private let sessionStore: SessionStore
    private let herdrPreferences: HerdrPreferencesStore
    private let debouncer = WorkspaceRefreshDebouncer(debounceInterval: 0.15, minInterval: 0.5)

    private var monitor: Any?
    private var lastFireDate: [Session.ID: Date] = [:]
    private var pendingWorkItems: [Session.ID: DispatchWorkItem] = [:]

    init(sessionStore: SessionStore, herdrPreferences: HerdrPreferencesStore) {
        self.sessionStore = sessionStore
        self.herdrPreferences = herdrPreferences
    }

    /// Installs the monitor. Never consumes -- always returns `event`
    /// unchanged, so this can never block a key/click from reaching the
    /// terminal (unlike `KeybindingMatcher`, which deliberately does).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { @MainActor [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard let id = sessionStore.selectedID,
              let session = sessionStore.sessions.first(where: { $0.id == id })
        else { return }

        guard WorkspaceRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: event.type == .keyDown || event.type == .leftMouseDown,
            sessionIsFocused: session.viewState.isFocused,
            supportsWorkspaces: LaunchTargetResolver.supportsWorkspaces(session.profile, sessionName: session.sessionName),
            showWorkspaces: herdrPreferences.showWorkspaces
        ) else { return }

        schedule(for: id)
    }

    private func schedule(for id: Session.ID) {
        let now = Date()
        let fireDate = debouncer.scheduledFireDate(now: now, lastFireDate: lastFireDate[id])

        pendingWorkItems[id]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastFireDate[id] = Date()
            self.pendingWorkItems[id] = nil
            self.sessionStore.fetchWorkspaces(for: id)
        }
        pendingWorkItems[id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireDate.timeIntervalSince(now)), execute: workItem)
    }
}
