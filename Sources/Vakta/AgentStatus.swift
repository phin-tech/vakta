//
//  AgentStatus.swift
//  Vakta
//
//  A per-session status derived from `herdr --session <name> agent list`, shown
//  as a colored dot in the sidebar. herdr manages AI coding agents whose
//  `agent_status` is "working" / "idle" (anything else is surfaced as
//  "attention"); a session's status is the busiest of its agents.

import Foundation

enum AgentStatus: Equatable {
    case working
    case attention
    case idle
    /// No agents, or status not (yet) known.
    case none
    /// A herdr session whose target can't be reliably queried (e.g.
    /// `--remote`) -- distinct from `.none` so the sidebar never displays a
    /// remote/unreachable server's status as if it had been queried and
    /// found nothing. `SessionStore.pollAgentStatus` sets this directly
    /// (never through a query) on every poll tick -- redundant after the
    /// first since a profile's target doesn't change at runtime, but
    /// harmless (never notifies -- see `AttentionNotifier.handleTransition`,
    /// which this status never actually reaches).
    case unavailable

    init(herdr raw: String) {
        switch raw.lowercased() {
        case "working", "busy", "running", "thinking":
            self = .working
        case "idle", "ready", "done", "complete":
            self = .idle
        default:
            // waiting / needs-input / error / anything unknown -> surface it.
            self = .attention
        }
    }

    /// Higher wins when aggregating a session's agents.
    private var rank: Int {
        switch self {
        case .working: return 3
        case .attention: return 2
        case .idle: return 1
        case .none, .unavailable: return 0
        }
    }

    static func busiest(_ statuses: [AgentStatus]) -> AgentStatus {
        statuses.max(by: { $0.rank < $1.rank }) ?? .none
    }
}

enum HerdrAgentStatus {
    /// Aggregated status for a herdr session on `target`'s server. Returns
    /// nil when the query fails (protocol mismatch, server down, `target`
    /// isn't herdr, …) so the caller can keep the last known value rather
    /// than flicker to "none".
    static func status(
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> AgentStatus? {
        guard let argv = target.statusArgv(sessionName: sessionName) else { return nil }
        guard let output = ProcessRunner.run(argv, path: path, environment: target.environment, isCancelled: isCancelled)
        else { return nil }

        guard let data = output.data(using: .utf8) else { return nil }
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        guard let agents = decoded?.result?.agents else { return nil } // error payload
        if agents.isEmpty { return AgentStatus.none }
        return AgentStatus.busiest(agents.map { AgentStatus(herdr: $0.agent_status) })
    }

    // Minimal shape of the `agent list` JSON; unknown keys are ignored.
    private struct Response: Decodable {
        let result: Result?
        struct Result: Decodable { let agents: [Agent] }
        struct Agent: Decodable { let agent_status: String }
    }
}
