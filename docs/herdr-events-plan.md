# Plan: herdr event subscriptions

Status: **approved for implementation, tracked as `vakta#s5n3`**. Follow the
phase gates in [AGENTS.md](../AGENTS.md) per slice below (RED: testing
strategy + failing tests only, halt for GREEN approval).

## Motivation

`SessionStore.pollAgentStatus` (`Sources/Vakta/SessionStore.swift`) refreshes
each herdr session's sidebar status dot on a flat 2.5s `Timer`, re-running
`herdr --session <name> agent list` as a subprocess every tick regardless of
whether anything changed. herdr's own socket API supports genuine server-push
event subscriptions that would replace this with near-instant updates and no
per-tick subprocess spawn.

## What was verified (spikes, 2026-09-16)

Ran hand-rolled raw JSON-over-Unix-socket clients (no herdr CLI, no mocks)
against a real, already-running local herdr server
(`~/.config/herdr/herdr.sock`) and confirmed:

- **Transport**: newline-delimited JSON over a Unix domain socket (Windows:
  named pipe -- out of scope, Vakta is macOS-only).
- **Plain request/response connections are single-shot.** A second `ping` on
  an already-answered connection gets `BrokenPipeError` -- the server closes
  the connection after one response unless that response was
  `subscription_started`. (Corrects an earlier read of this spike: the first
  attempt's "connection dropped" was normal one-shot behavior, not an
  error-handling edge case.)
- **A subscribed connection cannot take a second `events.subscribe`.**
  Sending one on an already-subscribed connection just gets the connection
  closed. **Consequence for the design below:** there is no "patch the
  subscription in place" -- changing which panes are subscribed means
  closing the connection and opening a new one with the full updated list.
- **Multiple `pane_id`s CAN share one connection and one request.** A single
  `events.subscribe` with a `subscriptions` array containing several
  `{"type":"pane.agent_status_changed","pane_id":"..."}` entries (different
  pane ids) delivered events for more than one of those panes down that one
  socket. **Consequence: one `HerdrEventStreamClient` connection per herdr
  session** (subscribed to every pane id currently belonging to that
  session's agents), not one connection per pane.
- **`pane.updated` does NOT fire on agent-status transitions.** Ran
  `pane.updated` (session-wide, no `pane_id` filter) and
  `pane.agent_status_changed` (per-pane) concurrently for 90s: five confirmed
  status transitions arrived on the status subscription, zero `pane.updated`
  events fired. Per-pane `agent_status_changed` subscriptions are required --
  there's no session-wide shortcut that avoids tracking pane ids.
- **`events.subscribe` requires `pane_id` per subscription** -- confirmed via
  `herdr api schema --json`: `pane.agent_status_changed`'s required fields are
  `["type", "pane_id"]`. There is no "all panes in this session" wildcard.
  Subscribing without `pane_id` returns `invalid_request`.
- **Optional narrowing**: a subscription can also filter to one target status
  (`{"type":"pane.agent_status_changed","pane_id":"w1:p1","agent_status":"blocked"}`),
  confirmed in herdr's own published example at
  `https://herdr.dev/docs/socket-api/#event-subscriptions`.
- **Real push events observed**, unprompted, from live dev sessions on this
  machine, across two separate confirmed pane ids:
  ```json
  {"id":"sub_1","result":{"type":"subscription_started"}}
  {"data":{"agent":"claude","agent_status":"working","pane_id":"w2C:p1","workspace_id":"w2C"},"event":"pane.agent_status_changed"}
  {"data":{"agent":"claude","agent_status":"done","pane_id":"w2C:p1","workspace_id":"w2C"},"event":"pane.agent_status_changed"}
  ```
  Note the pushed-event envelope uses `"event"`/`"data"` keys -- a different
  shape than the `"id"`/`"result"` request-response frames, so the decoder
  must branch on which keys are present.
- **`pane_id` is already in data Vakta discards.** `herdr agent list`'s real
  JSON response includes `pane_id` per agent
  (`{"result":{"agents":[{"agent_status":"...","pane_id":"w2D:p2",...}]}}`),
  but `AgentStatus.swift`'s `Response.Agent` currently decodes only
  `agent_status`. No new query is needed to learn pane ids -- just a wider
  decode of a response Vakta already fetches. The `pane list` output also
  showed non-agent panes with `agent_status: "unknown"` and no `agent`
  field -- any per-pane status tracking must exclude panes with no `agent`,
  or `AgentStatus(herdr:)`'s existing mapping will render them as attention.
- **Socket path resolution** (from `https://herdr.dev/docs/socket-api/`,
  "Socket paths"): `--session <name>` -> `~/.config/herdr/sessions/<name>/herdr.sock`,
  *except* `--session default`, confirmed by running `herdr --session default
  status` against the real client, which resolves to the root
  `~/.config/herdr/herdr.sock` (there is no `sessions/default/` on disk).
  Confirmed by direct test: `HERDR_SOCKET_PATH=/tmp/bogus-nonexistent.sock
  herdr --session default status` still reports the real default socket --
  **an explicit `--session <name>` wins over `HERDR_SOCKET_PATH`
  entirely.** Since Vakta always invokes herdr with `--session <name>`
  explicitly (never bare), `HerdrSocketPath` only needs `sessionName` as
  input, not `profile.environment` -- the env-var precedence levels in
  herdr's docs matter only for invocations Vakta doesn't make. (The
  `HERDR_SOCKET_PATH` scrubbing already done for spawned children in
  `Profile.herdr` stays as-is; unrelated to this resolution.)
- **Base config directory hardcoded to `~/.config/herdr` for v1.** herdr
  also supports `HERDR_CONFIG_PATH` to relocate its config *file*, which the
  socket directory presumably follows -- not verified, not handled. If a
  user overrides it, event subscription silently fails closed (falls back
  to the poll -- see Components below) rather than connecting to the wrong
  socket.
- **No built-in reconnect.** A dropped connection just stops the stream;
  Vakta owns all backoff/reconnect logic.
- **Bootstrap-gap guidance** (herdr's own docs): open `events.subscribe`
  first, buffer events, then call `session.snapshot`/`agent list`, install
  the snapshot, replay buffered events in order, then continue streaming.
  Skipping this ordering can miss an event between snapshot and subscribe.

## Design

### Scope for v1

Replace the agent-status poll only. Leave `workspace list`/`workspace
focus`/`session list` as one-shot subprocess calls -- they aren't polled
today, so switching them to events buys nothing until/unless a later change
adds live workspace-disclosure updates (see "Follow-ups" below).

### Design pivot: the socket is a trigger, not a data path

A single `pane.agent_status_changed` event only carries one pane's new
status. `SessionStore`'s sidebar dot is a *session's* status --
`AgentStatus.busiest(...)` across every agent pane in that session
(`AgentStatus.swift`'s doc comment: "a session with one agent still working
and another waiting on input must show attention, not working"). Rebuilding
that aggregate from a stream of single-pane deltas means duplicating
`HerdrAgentStatus.status`'s aggregation logic in a second, event-driven
path -- two places that can drift.

Instead: **the event stream doesn't carry status data into `SessionStore` at
all -- it only tells `SessionStore` *when* to re-run the existing,
unchanged, already-tested `pollAgentStatus()`/`HerdrAgentStatus.status`
subprocess call**, instead of waiting for the next 2.5s timer tick. This
also uses a schema fact confirmed above: `pane.created`, `pane.closed`, and
`pane.agent_detected` require only `"type"` (no `pane_id`) -- they're
already session-wide, no pane tracking needed for those. Combined with
per-pane `pane.agent_status_changed` subscriptions (which do need `pane_id`)
in the *same* connection/request (confirmed: multiple subscription entries
share one connection fine), one connection per herdr session covers both
"a pane appeared/disappeared" and "a pane's status changed" -- either kind
of event just triggers an immediate (debounced) poll.

This reuses `HerdrAgentStatus.status`, `AgentStatus.busiest`, and
`AgentStatusApplyPlanner.accepted(...)` completely unchanged. No new
aggregation logic, no per-pane status cache.

### Components

1. **`HerdrSocketPath`** (pure, `VaktaCoreTests`) -- given `sessionName`
   alone (see above -- `environment`/`HERDR_SOCKET_PATH` don't apply to
   Vakta's always-`--session`-explicit invocations), returns the resolved
   socket `URL`: `~/.config/herdr/herdr.sock` for `"default"`, else
   `~/.config/herdr/sessions/<sessionName>/herdr.sock`. Takes an injectable
   config-directory root (mirrors this codebase's "inject storage roots"
   convention, e.g. `ShellEnvironment.fallbackPATH(home:)`) so tests don't
   touch the real `~/.config/herdr`. No I/O.
2. **`HerdrSocketFrame`/`HerdrSocketDecoder`** (pure, `VaktaCoreTests`) --
   decodes one JSON line into a minimal typed result: `subscriptionAck`,
   `paneEvent(paneID: String?)` (any of the six trigger-worthy event types --
   the exact type doesn't matter to the caller, only "something happened"),
   `other` (a response/event this client doesn't act on -- e.g. a
   `pane.moved` if not subscribed, or an error response), or `malformed`
   (invalid JSON / unrecognized shape entirely -- a signal to the shell
   layer to log and reconnect). Table-driven against the fixture JSON lines
   captured in the spikes above, plus split-across-reads/multiple-frames-in-
   one-read framing cases (belongs in the decoder per the "Darwin
   `sun_path`" risk note below -- the shell layer must not need to
   reassemble partial lines itself).
3. **`HerdrPaneRegistry`** (pure, `VaktaCoreTests`) -- given the current
   known pane-id set and a fresh list of pane ids extracted from the next
   `agent list` poll result (excluding entries with no `agent` field -- see
   above), reports whether the set changed and, if so, the new full set.
   This is the only input to deciding whether `HerdrEventStreamClient` needs
   to reconnect with an updated subscription list (confirmed above: no live
   patching). Deliberately does **not** track per-pane status -- see the
   pivot above.
4. **`HerdrEventStreamClient`** (imperative shell, `VaktaIntegrationTests`)
   -- owns one socket connection per herdr session, subscribed in one
   `events.subscribe` request to `pane.created`/`pane.closed`/
   `pane.agent_detected` (session-wide) plus `pane.agent_status_changed` for
   every pane id in `HerdrPaneRegistry`'s current set. Connects via
   `HerdrSocketPath`, reads newline-delimited frames on a background queue,
   decodes via `HerdrSocketDecoder`, and calls a debounced `onTrigger: () ->
   Void` closure for any `paneEvent`/`malformed` frame -- it does not hand
   status data back to the caller at all. Reconnects (with jittered backoff)
   whenever `HerdrPaneRegistry` reports a changed pane set, on any decode
   failure, or on connection drop. Owns its own cancellation/stop path
   (per advisor: not another `nonisolated(unsafe)` flag) alongside
   `SessionStore`'s existing `isShuttingDown` shutdown signal. Tested
   against a **real fixture Unix socket server** (a small in-test listener
   speaking the subset of the protocol needed -- short fixed path under
   `/tmp`, not the shared UUID-suffixed temp-directory helper, per the
   `sun_path` risk below), matching the "real fixture, no mocks" style of
   `BoundedProcessRunnerShellTests`/`LaunchTargetShellTests`.
5. **`SessionStore` integration** -- one `HerdrEventStreamClient` per live
   herdr session, created alongside the session and torn down when it
   closes, whose `onTrigger` calls the existing `pollAgentStatus()` early
   (debounced so a burst of events collapses to one poll). The 2.5s
   `Timer`/`pollAgentStatus` stays as-is, unchanged, as the fallback cadence
   for sessions whose socket connection is down or hasn't connected yet --
   defense in depth, and zero risk to the existing, well-tested poll path.
   Each `pollAgentStatus()` run also feeds its `agent list` result's pane
   ids into that session's `HerdrPaneRegistry` to detect membership changes.

### Testing strategy shape (per AGENTS.md's RED gate, for whoever picks this up)

- **Functional core**: `HerdrSocketPath`, `HerdrEventDecoder`,
  `HerdrPaneRegistry` -- pure input/output, no sockets, no timers.
- **Imperative shell**: `HerdrEventStreamClient` against a real fixture
  socket server -- connect, bootstrap ordering (subscribe before snapshot),
  malformed/dropped-connection reconnect with backoff, clean shutdown
  (mirrors `docs/testing.md`'s existing patterns for bounded subprocess
  lifecycle, applied to a socket instead of a process).
- Add a row to `docs/testing.md`'s Priority 1/2 table once this actually
  starts (not yet added -- this doc is pre-implementation).

## Open questions / risks

- **Reconnect storms**: if the herdr server restarts, every open herdr
  session's `HerdrEventStreamClient` will try to reconnect simultaneously.
  Needs jittered backoff, not fixed-interval retry.
- **Pane churn**: an agent's pane id can presumably change across a full
  session restart (not confirmed) -- `HerdrPaneRegistry` needs a real test
  case for "old pane id list is entirely stale, resubscribe from scratch."
- **Darwin `sun_path` limit (104 bytes)**: the fixture Unix socket server in
  `HerdrEventStreamClient`'s tests must use a short socket path --
  `FileManager.default.temporaryDirectory` + a UUID-suffixed directory name
  (the pattern used elsewhere in this test suite) is long enough to risk
  `EINVAL`/`ENAMETOOLONG` for a socket bind specifically, even though it's
  fine for regular files. Use a short fixed suffix under `/tmp` directly for
  this one fixture, not the shared temp-directory helper.
- **Client/fixture-server transport choice**: `NWConnection`/`NWListener`
  with `NWEndpoint.unix(path:)` is the likely idiomatic route compatible
  with the deployment target (macOS 13) for both the real client and the
  in-test fixture server -- confirm it actually compiles/behaves as expected
  before committing to it in slice 2; fall back to POSIX sockets +
  `DispatchSource` if not. Either way, the newline-framing logic (a read can
  split a frame across two `recv`s, or deliver two frames in one) belongs in
  the pure decoder, with explicit test cases for both.

## Follow-ups (not v1)

- Live workspace-disclosure updates via `workspace.*` events, replacing the
  current fetch-on-expand-only `HerdrWorkspaceQuery`.
- `pane.output_matched` for a "notify when this pane's output matches X"
  primitive, if a future feature wants it (e.g. "notify when the build
  finishes" independent of agent status).
- Narrowing agent-status subscriptions with the optional `agent_status`
  filter (e.g. subscribe only to the `blocked` transition) if profiling
  shows the unfiltered per-pane subscription volume matters.
