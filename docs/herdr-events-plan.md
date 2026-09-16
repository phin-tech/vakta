# Plan: herdr event subscriptions

Status: **proposed, not started**. This is a design document, not an
authorization to implement -- follow the phase gates in
[AGENTS.md](../AGENTS.md) (RED: testing strategy + failing tests only; wait
for approval before GREEN) before writing production code against this plan.

## Motivation

`SessionStore.pollAgentStatus` (`Sources/Vakta/SessionStore.swift`) refreshes
each herdr session's sidebar status dot on a flat 2.5s `Timer`, re-running
`herdr --session <name> agent list` as a subprocess every tick regardless of
whether anything changed. herdr's own socket API supports genuine server-push
event subscriptions that would replace this with near-instant updates and no
per-tick subprocess spawn.

## What was verified (spike, 2026-09-16)

Ran a hand-rolled raw JSON-over-Unix-socket client (no herdr CLI, no mocks)
against a real, already-running local herdr server
(`~/.config/herdr/herdr.sock`) and confirmed:

- **Transport**: newline-delimited JSON over a Unix domain socket (Windows:
  named pipe -- out of scope, Vakta is macOS-only).
- **Request/response framing**: one JSON object per line;
  `{"id":"req_1","method":"ping","params":{}}` gets
  `{"id":"req_1","result":{...}}`; a bad request gets
  `{"id":"...", "error":{"code":"invalid_request","message":"..."}}` on the
  *same* connection (doesn't necessarily close it -- but a bad request sent
  before establishing the connection's first successful exchange did drop
  the connection in one trial, so treat any non-ack response to a subscribe
  as "reconnect," not just "log and continue").
- **`events.subscribe` requires `pane_id` per subscription** -- confirmed via
  `herdr api schema --json`: `pane.agent_status_changed`'s required fields are
  `["type", "pane_id"]`. There is no "all panes in this session" wildcard.
  Subscribing without `pane_id` returns `invalid_request`.
- **Optional narrowing**: a subscription can also filter to one target status
  (`{"type":"pane.agent_status_changed","pane_id":"w1:p1","agent_status":"blocked"}`),
  confirmed in herdr's own published example at
  `https://herdr.dev/docs/socket-api/#event-subscriptions`.
- **Real push events observed**, unprompted, from live dev sessions on this
  machine:
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
  decode of a response Vakta already fetches.
- **Socket path resolution** (from `https://herdr.dev/docs/socket-api/`,
  "Socket paths"): `--session <name>` -> `~/.config/herdr/sessions/<name>/herdr.sock`;
  else `HERDR_SOCKET_PATH`; else `HERDR_SESSION`; else the default session
  socket. Vakta must replicate this resolution itself for a raw socket
  connection (there's no CLI step that does it for us) -- the inputs
  (`sessionName`, `profile.environment["HERDR_SOCKET_PATH"]`) already exist
  on `MultiplexerTarget` (`Sources/Vakta/LaunchTarget.swift`).
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

### Components

1. **`HerdrSocketPath`** (pure, `VaktaCoreTests`) -- given `sessionName` and
   `environment`, replicates herdr's own socket resolution order above.
   No I/O.
2. **`HerdrEventFrame`/`HerdrEventDecoder`** (pure, `VaktaCoreTests`) --
   decodes one JSON line into a typed result: a response frame (`id` +
   `result`/`error`) or a pushed event frame (`event` + `data`), and within
   the latter, the specific `pane.agent_status_changed` payload shape
   (`pane_id`, `agent_status`). Table-driven against the fixture JSON lines
   captured in the spike above, plus malformed/unknown-field cases.
3. **`HerdrPaneRegistry`** (pure, `VaktaCoreTests`) -- new component the
   spike surfaced as necessary: since subscriptions are per-`pane_id` with
   no session-level wildcard, something has to track "which pane ids belong
   to this herdr session's agents right now" from each `agent list`
   response, and compute the subscribe/unsubscribe delta when that set
   changes (a pane appears, disappears, or an agent attaches/detaches). Pure
   input (old pane-id set, new `agent list` result) -> output (pane ids to
   subscribe to, pane ids to drop).
4. **`HerdrEventStreamClient`** (imperative shell, `VaktaIntegrationTests`)
   -- owns one socket connection per herdr session: connects (via
   `HerdrSocketPath`), performs the subscribe-then-snapshot bootstrap
   sequence, reads newline-delimited frames on a background queue, decodes
   via `HerdrEventDecoder`, and republishes decoded events through a
   callback/`AsyncStream`. Owns reconnect-with-backoff and a cancellation
   flag, following `SessionStore`'s existing `isShuttingDown` /
   `SingleFlightGate` ownership patterns rather than introducing a new
   concurrency primitive. Tested against a **real fixture Unix socket
   server** (a small in-test listener that speaks the subset of the
   protocol needed), matching the "real fixture, no mocks" style of
   `BoundedProcessRunnerShellTests`/`LaunchTargetShellTests`.
5. **`SessionStore` integration** -- one `HerdrEventStreamClient` per live
   herdr session, created alongside the session and torn down when it
   closes. Decoded `pane.agent_status_changed` events feed into the
   *existing*, already-tested `AgentStatusApplyPlanner.accepted(...)`
   unchanged (it already guards stale/removed sessions -- no new decision
   logic needed there). The 2.5s `Timer`/`pollAgentStatus` either goes away
   entirely, or stays as a slow fallback poll for sessions whose socket
   connection is currently down (defense in depth: the subprocess path
   keeps working even if the socket client has a bug).

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
- **Error-response connection behavior wasn't fully pinned down** in the
  spike -- one malformed-request trial appeared to drop the connection
  before a first successful response, but a corrected request into the same
  code path returned a clean error without dropping. Needs a slightly more
  rigorous repro before relying on "errors don't close the connection" as an
  invariant the reconnect logic can skip handling.

## Follow-ups (not v1)

- Live workspace-disclosure updates via `workspace.*` events, replacing the
  current fetch-on-expand-only `HerdrWorkspaceQuery`.
- `pane.output_matched` for a "notify when this pane's output matches X"
  primitive, if a future feature wants it (e.g. "notify when the build
  finishes" independent of agent status).
- Narrowing agent-status subscriptions with the optional `agent_status`
  filter (e.g. subscribe only to the `blocked` transition) if profiling
  shows the unfiltered per-pane subscription volume matters.
