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

/// Whether a passthrough input event should refresh the file sidebar's root.
/// Independent of the workspace disclosure: switching panes in the focused
/// terminal changes the focused pane's working directory, and the file sidebar
/// follows it whenever it is shown -- no `showWorkspaces` requirement.
enum FileSidebarRefreshGate {
    static func shouldTrigger(
        eventIsKeyDownOrLeftMouseDown: Bool,
        sessionIsFocused: Bool,
        fileSidebarVisible: Bool
    ) -> Bool {
        eventIsKeyDownOrLeftMouseDown && sessionIsFocused && fileSidebarVisible
    }
}

/// Whether a passthrough input event should refresh the status bar's PR
/// state: switching panes (a key or click in the focused terminal) changes
/// which pane is focused, and the bar follows it.
enum PullRequestStatusRefreshGate {
    static func shouldTrigger(
        eventIsKeyDownOrLeftMouseDown: Bool,
        sessionIsFocused: Bool,
        statusBarEnabled: Bool
    ) -> Bool {
        eventIsKeyDownOrLeftMouseDown && sessionIsFocused && statusBarEnabled
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
    private let fileSidebarPreferences: FileSidebarPreferencesStore
    private let debouncer = WorkspaceRefreshDebouncer(debounceInterval: 0.15, minInterval: 0.5)

    private var monitor: Any?
    private var lastFireDate: [Session.ID: Date] = [:]
    private var pendingWorkItems: [Session.ID: DispatchWorkItem] = [:]
    /// Which refreshes a pending (debounced) fire owes, so a later event of a
    /// different kind can't cancel a refresh an earlier one asked for.
    private var pendingWorkspace: Set<Session.ID> = []
    private var pendingFileSidebar: Set<Session.ID> = []
    /// The status bar's pane-switch refresh: one pane listing of the selected
    /// session (milliseconds; cached PR data is shown at once and any due
    /// fetch runs separately), so ~0.1 s after the last input, at most every
    /// 0.4 s while typing.
    private let pullRequestDebouncer = WorkspaceRefreshDebouncer(debounceInterval: 0.1, minInterval: 0.4)
    private var lastPullRequestFireDate: Date?
    private var pendingPullRequestWork: DispatchWorkItem?

    init(
        sessionStore: SessionStore,
        herdrPreferences: HerdrPreferencesStore,
        fileSidebarPreferences: FileSidebarPreferencesStore
    ) {
        self.sessionStore = sessionStore
        self.herdrPreferences = herdrPreferences
        self.fileSidebarPreferences = fileSidebarPreferences
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

        let isInput = event.type == .keyDown || event.type == .leftMouseDown
        let focused = session.viewState.isFocused
        let workspace = WorkspaceRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: isInput,
            sessionIsFocused: focused,
            supportsWorkspaces: LaunchTargetResolver.supportsWorkspaces(session.profile, sessionName: session.sessionName),
            showWorkspaces: herdrPreferences.showWorkspaces
        )
        let fileSidebar = FileSidebarRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: isInput,
            sessionIsFocused: focused,
            fileSidebarVisible: fileSidebarPreferences.isVisible
        )
        if PullRequestStatusRefreshGate.shouldTrigger(
            eventIsKeyDownOrLeftMouseDown: isInput,
            sessionIsFocused: focused,
            statusBarEnabled: sessionStore.isPullRequestStatusEnabled
        ) {
            schedulePullRequestRefresh()
        }
        guard workspace || fileSidebar else { return }

        if workspace { pendingWorkspace.insert(id) }
        if fileSidebar { pendingFileSidebar.insert(id) }
        schedule(for: id)
    }

    private func schedulePullRequestRefresh() {
        let now = Date()
        let fireDate = pullRequestDebouncer.scheduledFireDate(now: now, lastFireDate: lastPullRequestFireDate)
        pendingPullRequestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastPullRequestFireDate = Date()
            self.pendingPullRequestWork = nil
            self.sessionStore.refreshPullRequestStatus(onlySelectedSession: true)
        }
        pendingPullRequestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireDate.timeIntervalSince(now)), execute: work)
    }

    private func schedule(for id: Session.ID) {
        let now = Date()
        let fireDate = debouncer.scheduledFireDate(now: now, lastFireDate: lastFireDate[id])

        pendingWorkItems[id]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastFireDate[id] = Date()
            self.pendingWorkItems[id] = nil
            if self.pendingWorkspace.remove(id) != nil {
                self.sessionStore.fetchWorkspaces(for: id)
            }
            if self.pendingFileSidebar.remove(id) != nil {
                self.sessionStore.refreshFileSidebarRoot()
            }
        }
        pendingWorkItems[id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireDate.timeIntervalSince(now)), execute: workItem)
    }
}
