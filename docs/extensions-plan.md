# Plan: Extensions

Status: **implemented 2026-10-03 on branch `extensions` (all nine slices, `vakta#3kav`); desktop checks pending** (see [testing.md](testing.md), desktop step 13). Follow-up: `vakta#b3hb` (CLI linking). Vocabulary is in
[CONTEXT.md](../CONTEXT.md), and the architectural decision is in
[ADR 0001](adr/0001-out-of-process-extensions.md). Kata is the first
Extension, and its needs set v1 scope: nothing is added to the protocol
until a real Extension uses it.

## Goal

Show Kata issues for whatever you're working on (Panel View, Status Item,
Session Badges), and act on them natively (claim, close, comment, create,
start an agent in a pane), without compiling Kata into Vakta.

## Model

- **Linked Extension**: a local directory with `vakta-extension.json`,
  registered in Preferences ▸ Extensions (a `vakta extension link <dir>`
  CLI is a follow-up). v1 does not install from GitHub.
- **Trust**: approval is pinned to the manifest's hash plus the hash of the
  executable `command[0]` resolves to, inside the Extension directory. Any
  change asks again. **Developer mode** (per Linked Extension) pins only
  the manifest. The Trust prompt says which of the two is being approved.
- **Process**: one long-lived child per trusted, enabled Extension, started
  at app launch. Newline-delimited JSON-RPC 2.0 over stdin/stdout; stderr
  goes to the Extension log (`<support>/extension-logs/<id>.log`). The
  child's environment is built explicitly (resolved PATH, HOME, LANG,
  `VAKTA_EXTENSION_ID`, `VAKTA_EXTENSION_ROOT`, `VAKTA_EXTENSION_CONFIG_DIR`
  = `<support>/extension-data/<id>`, `VAKTA_EXTENSION_API`) without changing
  Vakta's own environment. On quit or disable: `shutdown`, grace period,
  then SIGKILL the child. (The child isn't put in its own process group, so
  grandchildren it spawns must exit on their own when their stdin closes.)
- **Failure**: a down Extension's Contributions are removed immediately,
  never shown stale. Vakta restarts it with backoff. Repeated crashes mark
  it **Failed** (Preferences: Restart, View log). A Panel View shows an
  error empty state with Restart and View log. No notifications.
- **Versioning**: `initialize` exchanges `vakta_extension_api`. A mismatch
  marks the Extension Failed with the reason.

## Manifest

JSON, not TOML: Vakta has no TOML parser (`HerdrConfigDocument` deliberately
isn't one), and JSON matches the protocol.

```json
{
  "id": "kata",
  "name": "Kata",
  "command": ["./.build/release/kata-vakta", "serve"],
  "build": [["swift", "build", "-c", "release"]],
  "panelViews": [{"id": "issues", "title": "Issues", "symbol": "checklist"}]
}
```

`environment` (optional) lists login-shell variables the Extension
receives: exact names or `PREFIX_*` (Kata declares `KATA_*` for its auth
token). Nothing else from the user's environment is passed, and PATH, HOME,
LANG and `VAKTA_*` can't be requested. The list is part of the manifest, so
approval covers it and the review sheet shows it.

`command[0]` must be a relative path inside the Extension directory, never a
bare program name or an absolute path, because Trust pins that file. Build
commands run through `/usr/bin/env` with the resolved login-shell PATH, in
the Extension directory, only after the user approves.

Status Items and Session Badges are declared implicitly: an Extension
that sends none has none.

## Protocol

Host → Extension:

| Message | Kind | Purpose |
|---|---|---|
| `initialize` | request | API version, host capabilities |
| `contexts/changed` | notification | full snapshot of every Session's Extension Context |
| `view/render {view}` | request → View Document | Panel View content |
| `callback {view, callback, payload, form?}` | request → `{effects}` | button or form submit |
| `$/cancel {id}` | notification | drop an in-flight request |
| `shutdown` | request | graceful stop |

Extension → host:

| Message | Purpose |
|---|---|
| `view/update {view, document}` | push fresh Panel View content |
| `view/invalidate {view}` | ask Vakta to re-render |
| `status/set {text, symbol?, popover?}` / `status/clear` | the one Status Item |
| `badge/set {sessionKey, text, symbol?, popover?}` / `badge/clear` | Session Badges |
| `log {level, message}` | Extension log |

**Extension Context** (one per Session): `sessionKey` (backend + multiplexer
session name, stable across restarts; not `Session.id`, which is a new
UUID each launch), `cwd` (active pane), `gitRoot?`, `branch?`, `workspace`,
`focused`. Getting an unfocused Session's cwd means querying its active pane.
That runs on Session changes and on refresh, never per keystroke.

**View Document**: `list` (view-level header buttons, sections, rows with
title, subtitle, SF Symbol, accessories and buttons; filtering happens in
Vakta) | `detail` (markdown,
fields, buttons) | `form` (text, multiline, picker, toggle, submit
Callback). Buttons carry `callback`, `payload`, `style`, an optional
`confirm`, and an optional `shortcut`. Shortcuts only work while the view has
focus and go through `KeybindingMatcher`. Native text fields keep normal
text entry.

**Effects** (applied in order): `refresh`, `replace {document}`,
`push {document}`, `pop`, `toast {text}`, `notify {title, body}`,
`open_url {url}`, `open_pane {cwd, command, title}` (focused Session's
backend; fails visibly if it can't split), `open_session {cwd, command,
title}` (defined in the protocol; Kata v1 doesn't use it).

**Button state**: `idle → pending → idle | failed(message)`. One Callback
at a time per (view, callback, payload). Stale results (the Extension
Context changed while pending) drop view Effects but keep `toast` and
`notify`.

## Contributions

- **Panel View**: a toggle button after Files and Changes in the right
  panel, with extras beyond two in a `⋯` menu. The saved mode is
  `extension:<id>/<view>`. When that Extension is unavailable, the panel
  shows Files without erasing the saved choice.
- **Status Item**: one per Extension, after the built-in segments, in link
  order, ~20 characters at most. It counts as content for `auto`
  visibility. Hover or pin opens a Popover through the existing
  `StatusBarPopover` machinery.
- **Session Badge**: one per Extension per Session row, ~8 characters at
  most, full text on hover. Only the first Badge (in link order) shows, with
  `+N` opening a Popover that lists all of them. Clicking a Badge opens its
  Popover. Session rows only, not Workspace rows.

## Kata Extension configuration

`<support>/extension-data/kata/config.json` (optional):

```json
{"agentCommand": ["claude", "{prompt}"]}
```

Each argv word may contain `{id}`, `{title}` and `{prompt}`; values are
substituted inside words, never split into new ones. *Start* claims the
issue if it's unowned, records which Session started it in `sessions.json`
(same directory), and opens the agent in a new pane of the focused Session.

## Code layout

- `VaktaExtensionKit`: a local Swift package with the protocol types, used
  by the app and the Kata Extension.
- `extensions/protocol/fixtures/*.json`: golden JSON, the real contract.
  Both the kit and the host decoder are tested against it.
- `extensions/kata/`: a separate SwiftPM package (`kata-vakta`), never a
  target in the root `Package.swift` or `project.yml`.

## Functional core / imperative shell

| Core (pure, `VaktaCoreTests`) | Shell (`VaktaIntegrationTests`, real processes) |
|---|---|
| manifest decode and validation; trust fingerprint comparison | directory hashing, persistence of links and Trust |
| JSON-RPC line codec | `Process` + pipes, line reader |
| supervisor `(state, event) → (state, [effect])`: start, backoff, Failed | timers, killing the process group |
| Extension Context snapshot from Session state | active-pane queries for every Session |
| View Document decode; list filtering, selection, navigation stack | SwiftUI rendering (display-dependent, manual check) |
| button state machine; Callback result → Effects; stale-result filtering | carrying out Effects |
| panel mode persistence and fallback; Badge/Status Item merge and ordering | status bar / sidebar wiring |

A fixture Extension (a small script in `Tests/`) that can echo, push,
crash, hang, and return each Effect drives the shell tests. No mocks.

## Slices

Each slice is one Kata child issue under the Extensions epic, and each is
end-to-end runnable.

1. **Protocol kit + golden fixtures**
2. **Link + Trust + Extensions preferences tab**
3. **Supervisor + Extension Contexts**: the Kata skeleton initializes and
   logs contexts
4. **Read-only Panel View**: Kata's issue list and detail for the focused
   Extension Context, live through `kata events` → `view/update`
5. **Callbacks + core Effects**: Kata *Claim*
6. **Forms**: Kata *Close*, *Comment*, *New*
7. **`open_pane` / `open_session`**: Kata *Start* in a pane, plus Kata's
   Session Key → issue map
8. **Status Item + Popover**: Kata "N ready"
9. **Session Badges**: Kata issue per Session

Order: 1, 2 → 3 → 4 → 5 → {6, 7}; 4 → 8 → 9.

## Coverage-plan cases to select

Persistence (panel mode decode: old `files`/`changes`, unknown id, corrupt
file; linked/trusted registry), subprocess bounds (timeouts, hang, crash),
stale asynchronous state (Extension Context generation, Session switch
during a Callback), key routing (form text entry vs matcher, focus-scoped
shortcuts). See [testing.md](testing.md).
