//
//  AgentStatus.swift
//  Vakta
//
//  A per-session status derived from `herdr --session <name> agent list`, shown
//  as a colored dot in the sidebar. herdr manages AI coding agents whose
//  `agent_status` is "working" / "idle" (anything else is surfaced as
//  "attention"); a session's status is the busiest of its agents -- and
//  `.attention` outranks `.working`, deliberately: a session with one agent
//  still working and another waiting on input must show attention, not
//  working, or the waiting agent's need is hidden behind the busy one.

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
    /// harmless (never notifies -- `AttentionTransitionPolicy.decide`
    /// treats any transition to `.unavailable` as silent, tested).
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

    /// Higher wins when aggregating a session's agents. `.attention` is
    /// highest -- a waiting agent's need must never be hidden behind a
    /// still-working one (see the type's doc comment).
    private var rank: Int {
        switch self {
        case .attention: return 3
        case .working: return 2
        case .idle: return 1
        case .none, .unavailable: return 0
        }
    }

    static func busiest(_ statuses: [AgentStatus]) -> AgentStatus {
        statuses.max(by: { $0.rank < $1.rank }) ?? .none
    }
}

enum HerdrAgentStatus {
    /// `status` plus the pane ids behind it, from one decoded `agent list`
    /// response -- lets a caller that needs both (`SessionStore.pollAgentStatus`,
    /// which also feeds `HerdrPaneRegistry`) avoid a second subprocess call.
    struct QueryResult: Equatable {
        var status: AgentStatus
        var paneIDs: Set<String>
    }

    /// Runs `agent list` once and returns both the aggregated status and the
    /// pane ids behind it. Returns nil when the query fails (protocol
    /// mismatch, server down, `target` isn't herdr, …) so the caller can
    /// keep the last known value rather than flicker to "none".
    static func query(
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> QueryResult? {
        guard let argv = target.statusArgv(sessionName: sessionName) else { return nil }
        guard let output = ProcessRunner.run(argv, path: path, environment: target.environment, isCancelled: isCancelled)
        else { return nil }
        return parse(agentListJSON: output)
    }

    /// Aggregated status for a herdr session on `target`'s server. Same
    /// query as `query`, discarding the pane ids -- kept as its own entry
    /// point for callers that only need the status.
    static func status(
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> AgentStatus? {
        query(sessionName: sessionName, target: target, path: path, isCancelled: isCancelled)?.status
    }

    /// Every agent's `pane_id` from an `agent list` JSON response -- the
    /// input `HerdrPaneRegistry` needs to detect pane membership changes.
    /// `pane_id` is optional on `Agent` (rather than required) so a response
    /// missing it -- as some fixtures/older payloads may -- still decodes
    /// for `status`/`query`; such agents are simply excluded here. Empty on
    /// any decode failure or error payload, same as `status`.
    static func paneIDs(fromAgentListJSON json: String) -> Set<String> {
        parse(agentListJSON: json)?.paneIDs ?? []
    }

    /// Pure: decodes one `agent list` JSON response into both derived
    /// values at once. `nil` on decode failure or an error payload.
    private static func parse(agentListJSON json: String) -> QueryResult? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let agents = decoded.result?.agents
        else { return nil }
        let status = agents.isEmpty ? AgentStatus.none : AgentStatus.busiest(agents.map { AgentStatus(herdr: $0.agent_status) })
        return QueryResult(status: status, paneIDs: Set(agents.compactMap(\.pane_id)))
    }

    // Minimal shape of the `agent list` JSON; unknown keys are ignored.
    private struct Response: Decodable {
        let result: Result?
        struct Result: Decodable { let agents: [Agent] }
        struct Agent: Decodable { let agent_status: String; let pane_id: String? }
    }
}
