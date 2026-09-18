# Terminal multiplexer backends

A durable reference for what each terminal-multiplexer backend Vakta talks to
can actually do, framed as capabilities. Vakta discovers, attaches to, and
introspects sessions living inside a multiplexer (herdr today; tmux partially;
others later). This file records which of those operations each backend
supports, how it addresses a specific server, and where the equivalents differ
-- so adding the next tool (rmux, zellij, ...) is a matter of answering the
same checklist and adding a column, not rediscovering it.

See also: [architecture.md](architecture.md) for the codebase's cross-cutting
invariants, and [herdr-events-plan.md](herdr-events-plan.md) for the herdr
event-subscription design specifically.

## How Vakta models a backend

A backend is a **value type, not a subclass.** `MultiplexerTarget`
(`Sources/Vakta/LaunchTarget.swift`) is resolved from a `Profile` alone (no
process execution) and carries the backend kind plus everything needed to
address one specific server: the executable path verbatim, tmux socket
flags, and the profile's environment. For the operations it models today, it
vends the argv and returns `nil` where a backend has no equivalent.

This is deliberate. The variation is **per session, not per store**: one
Vakta window hosts a heterogeneous list -- a herdr session, a tmux session,
and a plain shell -- managed by a single `SessionStore`. Subclassing the store
cannot express "this window has one of each." A capability model can: a
backend opts into a feature by vending argv (or a client) for it, rather than
by its command name. `SessionDiscovery.names(for:)` consumes a resolved target
for both herdr and tmux; the argv switch lives on the target (`discoveryArgv`)
and the output-parse switch lives in `SessionDiscovery`.

**Current state (2026-09-18).** The model is only partly realized in code.
On the target today: `discoveryArgv`, `statusArgv`, `workspaceListArgv`,
`workspaceFocusArgv`, `eventStreamSocketPath` (the last four `nil` for
non-herdr backends, `LaunchTarget.swift`). *Not* on the target: attach is the
profile's `arguments` template (`Profile.swift`). Two capability checks are
unified so far: the sidebar/palette workspace disclosure derives from
`LaunchTargetResolver.supportsWorkspaces` (`LaunchTarget.swift`), which both
`SidebarView.supportsWorkspaces` (`SidebarView.swift:362`) and
`AppDelegate.supportsWorkspaces` (`App.swift:719`) delegate to rather than
each checking `target.backend == .herdr` independently (`vakta#3cwd`); and
`SessionStore.startHerdrEventClientIfApplicable` (`:735`) now asks
`target.eventStreamSocketPath(sessionName:)` instead of gating on
`lastPathComponent == "herdr"` and hardcoding `HerdrSocketPath.resolve` at the
call site (`vakta#52mr`); and `SessionStore.pollAgentStatus` (`:476`) now
selects sessions via `LaunchTargetResolver.agentStatusPollOutcome`, derived
from `statusArgv != nil`, instead of `lastPathComponent == "herdr"`
(`vakta#2bwd`). No remaining `SessionStore` call site gates on the command
name. "Opts in by capability, not by name" now holds for every call site this
epic (`vakta#63w2`) covers.

The palette/sidebar workspace *model* is also neutralized (`vakta#daxg`):
`SessionStore.workspaces`/`fetchWorkspaces`/`focusWorkspace`,
`PaletteCategory.workspace`, `PaletteItemKind.focusWorkspace`,
`PaletteItemAssembler.assemble(workspaces:)`, and
`SessionSwitcherModel.replaceWorkspaces`'s row filter all carry no
herdr-specific names -- `Workspace.swift` (formerly `HerdrWorkspace.swift`)
holds the neutral `Workspace` value and `WorkspaceQuery.parse` dispatches on
`target.backend`.

tmux now has a workspace analogue too (`vakta#43sg`): `workspaceListArgv`
vends `list-windows -t <session> -F '#{window_id}|#{window_name}|#{window_active}'`
(`|`, not a tab -- tmux's `-F` engine substitutes "unprintable" bytes,
including a tab delimiter, with `_` when it can't detect a UTF-8 locale,
which `ProcessRunner`'s deliberately minimal environment (`PATH`/`HOME`
only) never provides; confirmed live and covered by a real-tmux-server
regression test in `LaunchTargetShellTests`)
(honoring `-S`/`-L`) and `workspaceFocusArgv` vends `select-window -t
<session>:<window>` -- deliberately *not* also `switch-client`: probed
against a throwaway tmux 3.7b server, `switch-client -t <session>` fails
with "no current client" when run from a detached subprocess (there's no
invoking client to switch), which would poison the whole chained command.
Bringing the Vakta session forward is `SessionStore.focusWorkspace`'s own
`select(id)` call, not this argv's job. `WorkspaceQuery.parse` gained a
`parseTmux` case alongside `parseHerdr`. Because `supportsWorkspaces` and
`fetchWorkspaces`/`focusWorkspace` were already capability-driven (`#3cwd`,
`#daxg`), tmux windows now surface in the sidebar disclosure and the ⌘K
switcher with no new UI branch -- the epic's stated end state for the
workspace analogue. Agent status stays herdr-only (`statusArgv` still `nil`
for `.tmux`, no native concept), and tmux's control-mode event stream is
still out of scope.

## The capability checklist

Answer these for any backend. Each maps to a `MultiplexerTarget` member or a
shell integration point; a capability a backend lacks is a legitimate `nil`,
not a gap to paper over.

1. **List sessions** -- enumerate the servers/sessions this target hosts.
2. **Attach** -- re-attach a running session into a Vakta terminal.
3. **Custom server addressing** -- how a profile points at one specific server
   instance rather than the default.
4. **Workspace analogue** -- the backend's sub-session grouping (herdr
   workspaces; tmux windows; zellij tabs), if any: enumerate + focus.
5. **Agent status** -- a per-pane "what agent/command is running" signal, if the
   backend exposes one natively.
6. **Event stream** -- an external, subscribable stream of session/pane changes
   (drives live sidebar updates instead of polling), if any.
7. **Active pane working directory** -- the currently focused pane's cwd, for
   a one-shot action (not a poll) like "Open in Editor."

## Capability matrix

Verified against the binaries on a developer machine on 2026-09-18: **tmux
3.7b**, **zellij 0.45.1**. herdr reflects Vakta's current integration. Probes
to reproduce: `tmux list-commands`, `man tmux` (§ CONTROL MODE), `zellij
--help`, `zellij action --help`, and per-subcommand `--help`.

| Capability | herdr | tmux 3.7b | zellij 0.45.1 |
|---|---|---|---|
| **List sessions** | `session list` | `list-sessions` | `list-sessions -n -s` (`--no-formatting --short` for parsing) |
| **Attach** | attach via profile `arguments` | `attach-session -t <name>` (built-in profile uses `new-session -A -s`) | `attach -c <name>` (create-if-absent); also `watch` (read-only) |
| **Custom server addressing** | `--session <name>` global flag (per-session socket); `HERDR_SOCKET_PATH` honored only by bare invocations like `session list` | `-S <socket-path>` / `-L <socket-name>` | `--session <name>` global flag; `ZELLIJ_SOCKET_DIR` env — no `-S`/`-L` |
| **Workspace analogue** | native workspaces (`workspace list`) | **windows**: `list-windows -t <session>` | **tabs**: `action list-tabs --json` (also `query-tab-names`) |
| **Focus workspace** | `workspace focus <id>` | `select-window` / `switch-client` | `action go-to-tab-name` / `go-to-tab-by-id` |
| **Agent status** | native `agent list` | none native — derivable from `list-panes -F '#{pane_current_command}'` | none native — derivable from `list-panes -c -j` (running command per pane) |
| **Last command status** | shell integration callback | Vakta stores the shell integration exit code in `@vakta_last_exit` per window | not implemented |
| **Event stream** | socket subscription (`HerdrEventStreamClient`) | control mode `tmux -C` / `-CC` (`%output`, `%window-add`, `%session-changed`, `%layout-change`, …) | `subscribe --pane-id … --format json` (render/scrollback updates) |
| **Active pane working directory** | `pane current` (`result.pane.cwd`/`foreground_cwd`; exactly one `focused: true` pane per session, confirmed live) | `display-message -p -t <session> '#{pane_current_path}'` | not surveyed — `action list-panes` likely carries a cwd field, unconfirmed |

zellij's `--session <name>` global flag reads "Specify name of a new session"
in `--help`, but it also targets an existing session for `action` and
`subscribe` (whose usage is `zellij [--session <OTHER SESSION NAME>]
subscribe …`).

## Per-capability notes

**List sessions is universal** and already backend-agnostic in code:
`MultiplexerTarget.discoveryArgv` builds the argv, `SessionDiscovery` runs it
and switches only on output parsing (`parseHerdr` vs `parseLines`). zellij fits
the same shape.

**The workspace analogue is a shared concept with a different noun per
backend** -- herdr workspaces, tmux windows, zellij tabs -- but all three
enumerate directly: herdr `workspace list`, tmux `list-windows -t <session>`,
zellij `action list-tabs --json`. So it's "argv + a per-backend parser" across
the board, mirroring the discovery split; there's no zellij-specific
asymmetry here.

**Agent status is herdr-specific as a native concept.** Neither tmux nor
zellij has an "agent" idea, but both can synthesize a per-pane running command
-- tmux `list-panes -F '#{pane_current_command}'`, zellij `list-panes -c -j`.
Whether that's worth wiring up is a separate question; today, for these
backends, `statusArgv` returns `nil`.

**tmux command status is a separate capability from agent status.** The pinned
Ghostty shell integration reports OSC 133 command completion to Vakta. For a
tmux session, Vakta resolves the active window and stores the exit code in the
namespaced window option `@vakta_last_exit`; workspace enumeration includes that
option so the sidebar can show a green circle for `0` and a red circle for any
nonzero result. The value is unknown until the first shell-integrated command
completes, and the command-status path is deliberately not presented as an
agent status.

**Event streams exist in all three but are not the same abstraction.** herdr's
is a structural session/pane event socket. tmux control mode (`-C`, or `-CC`
to disable echo) is the canonical structural stream: a client that emits
`%`-prefixed notifications for output, window/session/layout changes. zellij's
`subscribe` is **render/scrollback-oriented** (`--format json` available) --
"what changed on screen," closer to output than to structural events. A
backend's event capability is therefore "vends a stream of shape X," not one
shared wire protocol.

**Active pane working directory is a one-shot query, not a poll -- and
pane-level, not agent-level.** herdr's `pane current` (not `agent list`,
which only covers panes hosting a detected agent and would miss a plain
shell) reports exactly one globally-focused pane per session-wide query,
confirmed live against a running session with a scrubbed `PATH`/`HOME`-only
environment (no `--pane`/tty dependence). `ActivePaneWorkingDirectoryQuery`
(`ActivePaneWorkingDirectory.swift`) is built on `BoundedProcessRunner.runRaw`
directly rather than `ProcessRunner`: herdr writes its error envelope to
stdout even on a non-zero exit code (confirmed live for
`server_not_running`), which `ProcessRunner.run` would silently discard.

**Server addressing: herdr and zellij share a model; tmux is the outlier.**
Both herdr and zellij address a server by **session name as a global
`--session` flag** -- every herdr `MultiplexerTarget` argv except
`discoveryArgv` passes `--session <name>` (`LaunchTarget.swift:77,84,91`), and
`Profile.herdr` deliberately scrubs `HERDR_SOCKET_PATH` (`Profile.swift:163`)
so it can't silently redirect. tmux is the one that addresses a distinct
server by socket, `-S <path>` / `-L <name>` (already modeled on
`MultiplexerTarget`). A new backend may introduce yet another mode.

## Adding a backend

1. Answer the seven checklist questions above from the tool's own CLI (`--help`,
   `list-commands`, man page) and add a matrix column with the date verified.
2. Add the backend to `MultiplexerTarget.Backend` and its `discoveryArgv` /
   `*Argv` members; return `nil` for capabilities the tool lacks.
3. Add output parsing to `SessionDiscovery` (and any workspace/status parser)
   for the tool's specific format.
4. If the tool has an event stream, model it as a capability the target vends,
   alongside the existing `HerdrEventStreamClient` rather than special-casing
   the command name.

The remaining command-name checks that a new backend would trip over live at
`SessionStore.swift:478` and `:736` (both `lastPathComponent == "herdr"`), plus
the `backend == .herdr` kind checks at `SidebarView.swift:364` and
`App.swift:721`. No live ticket tracks routing these through capability
queries; the earlier cleanup epic (`vakta#mkwv`) is closed. See "Current
state" above.

## Where it lives in the code

- `Sources/Vakta/LaunchTarget.swift` — `MultiplexerTarget`, `Backend`,
  per-operation argv, `LaunchTargetResolver`.
- `Sources/Vakta/SessionDiscovery.swift` — session listing + per-backend parse.
- `Sources/Vakta/HerdrWorkspace.swift`, `AgentStatus.swift` — herdr workspace
  and agent-status queries (the `nil`-for-other-backends capabilities today).
- `Sources/Vakta/HerdrEventStreamClient.swift` — the herdr event stream.
- `Sources/Vakta/SessionStore.swift` — the shell that orchestrates all of the
  above per session.
