//
//  SketchyBarPublisher.swift
//  Vakta
//
//  Shell for Vakta's SketchyBar item: runs `sketchybar` off the main actor
//  with what `SketchyBarSyncPlanner` decides, and remembers what it sent.
//

import Foundation

enum SketchyBarPublishOutcome: Equatable {
    case unchanged
    case published
    case removed
    /// No `sketchybar` executable was found.
    case unavailable
    case failed(ProcessResult)
}

/// Callers serialize `update` (one in flight at a time); `AppDelegate`
/// coalesces requests that arrive while one is running.
@MainActor
final class SketchyBarPublisher {
    nonisolated static let timeout: TimeInterval = 3
    private nonisolated static let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]

    private let executable: String?
    private let now: () -> Date
    private var state = SketchyBarSyncState()

    init(executable: String?, now: @escaping () -> Date = Date.init) {
        self.executable = executable
        self.now = now
    }

    /// Brings the bar in line with `enabled` and `statuses`; returns once
    /// any `sketchybar` command has finished.
    func update(enabled: Bool, statuses: [AgentStatus]) async -> SketchyBarPublishOutcome {
        let desired = SketchyBarItemPlanner.appearance(for: statuses)
        let action = SketchyBarSyncPlanner.action(state, enabled: enabled, desired: desired, at: now())
        let arguments: [String]
        switch action {
        case .none: return .unchanged
        case .publish(let appearance): arguments = SketchyBarCommand.publishArguments(appearance)
        case .remove: arguments = SketchyBarCommand.removeArguments
        }
        guard let executable else { return .unavailable }

        let result = await Self.run(executable, arguments)
        switch (action, result) {
        case (.publish(let appearance), .success):
            state = SketchyBarSyncState(shown: appearance, sentAt: now())
            return .published
        case (.remove, .success), (.remove, .nonZeroExit):
            // A nonzero exit means the item was already gone (a reload).
            state = SketchyBarSyncState()
            return .removed
        default:
            // State is left as it was, so the next update retries.
            return .failed(result)
        }
    }

    /// Takes the item off the bar as Vakta quits. Blocks (bounded by
    /// `timeout`): `applicationWillTerminate` can't await.
    func removeBeforeExit() {
        guard state.shown != nil, let executable else { return }
        _ = BoundedProcessRunner.run(
            executable: executable, arguments: SketchyBarCommand.removeArguments,
            environment: Self.environment, timeout: Self.timeout
        )
        state = SketchyBarSyncState()
    }

    /// `sketchybar --query bar`, for placing the menu; nil when the bar
    /// can't be reached.
    func queryGeometry() async -> SketchyBarGeometry? {
        guard let executable else { return nil }
        guard case .success(let json) = await Self.run(executable, SketchyBarCommand.queryBarArguments) else { return nil }
        return SketchyBarGeometry.parse(json)
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        await Task.detached {
            BoundedProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }.value
    }
}
