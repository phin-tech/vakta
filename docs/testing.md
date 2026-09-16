# Test coverage plan

## Baseline and scope

Updated 2026-09-16: `Package.swift` defines `VaktaCoreTests` and
`VaktaIntegrationTests` targets; `.github/workflows/ci.yml` runs `swift test`
(417 tests as of this update) plus `Tests/scripts/test_*.sh` (the release
version/signing/install scripts) on every push/PR, alongside `swift build`
and the generated Xcode app build. Every ticket in the tables below is
closed under kata epic `vakta#mkwv` -- the tables describe what was
actually implemented and where its coverage lives, not future work.
See [README.md](../README.md#contributing) for the exact commands.

This plan remains the reference for what a NEW behavior change in one of
these areas needs to keep covering; it is not a queue of unstarted work. Add
a row (or extend an existing one) when a change adds a new decision or
effect boundary, per "Coverage evidence and maintenance" below.

Implementation must follow the phase gates in [AGENTS.md](../AGENTS.md).

## Test layers and harness

| Layer | What it proves | Isolation |
| --- | --- | --- |
| Functional core | Decisions, parsing, migration, identity, and state transitions | Value inputs/outputs; supplied time/IDs; no application launch, files, process execution, or OS services |
| Imperative shell | Correct boundary behavior and resulting state | Temporary files, real fixture subprocesses, stateful in-memory adapters, real Combine/AppKit where feasible |
| Desktop integration | Surface lifetime, focus/input, rendering, native notifications | Logged-in macOS desktop with Metal and the pinned Ghostty dependency |

Homes: `Tests/VaktaCoreTests`, `Tests/VaktaIntegrationTests`, and the manual
"Desktop regression checklist" below (no automated desktop suite exists;
Metal-backed surfaces need a logged-in session -- see AGENTS.md's "Terminal
invariants"). Keep test code out of the application target. Isolate core
code in an importable module as needed; do not launch `VaktaMain` to test
decisions.

Start with XCTest compatible with the declared tooling. Core tests should avoid
AppKit/Ghostty imports. Nondisplay integration tests can run on macOS CI without
constructing Metal-backed surfaces. Give each test its own temporary storage and
owned resources, clean them up even on failure, and bound waits with diagnostics.
Avoid real user settings, existing multiplexer sessions, network endpoints, and
notification permissions in automated unit/integration tests.

`swift test` must execute a nonzero test suite in CI (it does: 417 tests as of
this update). Keep the existing SwiftPM and generated-Xcode build checks. Add
an Xcode test action only when the generated scheme has actual test targets
(it doesn't yet -- `swift test` covers `VaktaCoreTests`/`VaktaIntegrationTests`
directly). Document display prerequisites
and explicit skips; never count skipped desktop checks as passing coverage.

## Priority 1: data preservation and runtime correctness

| Area / issue | Functional core cases | Shell / integration cases |
| --- | --- | --- |
| Helper execution and PATH — `mc9g` | PATH extraction with noise/empty output; fallback choice; typed success/error outcomes | Output larger than pipe capacity; nonzero exit; invalid encoding; missing executable; timeout/cancellation; child ignoring termination; descendant holding stdout open; bounded cleanup; responsive launch |
| Polling/discovery lifecycle — `6g3c` | Accept only current generations/live IDs; retain prior status on failure; invalidate removed/edited targets; derive badge from accepted state | Controlled completion order; repeated timer ticks; remove session during pending poll; stop/start ownership; no unbounded in-flight work; no resurrected session status |
| Profile server identity — `b2ry` | Local/remote/backend/socket target resolution; same name on different endpoints; unsupported command classification; JSON/text response fixtures | Temporary executable reports argv/environment; custom executable/PATH used; independent same-named sessions; empty success distinguished from query failure |
| Launch planning and validation — `h4q9` | Placeholder quoting contexts; spaces, quotes, substitutions, semicolons, newlines, leading dashes; scrub/environment key validation; malformed editor lines; values containing `=` | Execute against harmless argument dumper in temp directory; injected marker never created; child environment scrubbed while parent stays intact; working directory honored |
| Persistence — `k916` | Round trips and migrations for profiles, workspace, appearance, sidebar, terminal, notifications, keybindings, passthrough; missing fields; unknown enums/future versions; malformed and extreme values | Absent vs unreadable/corrupt; preserve original bytes; atomic saves; write failure surfaced; no silent temp-root fallback; isolated storage; default seed and migration restart behavior |
| Workspace recovery — `njjm` (depends on `k916`) | Restore ordering, selected ID, missing profiles, empty workspace, working-directory overrides; transient command override excluded from durable state | Restore multiple records without partial file rewrites; interrupted restore preserves recovery data; deleted profile never silently launches another command; restart round trip |
| Agent attention — `vsn0` | Empty/mixed agent sets; aliases/unknown statuses; working plus waiting retains attention; baseline suppression; selected/frontmost suppression; repeat suppression; completion transition; independent banner/bounce settings | Parse real response fixtures; in-memory notification state; stale session activation; packaged-app permission denial, delivery failure, click activation, and Dock behavior |
| Herdr workspace disclosure (local only) — `hyac` | `workspaceListArgv`/`workspaceFocusArgv` construction (herdr only, nil for tmux); `HerdrWorkspace` decode of the real `result.workspaces[]` shape ignoring unknown keys, empty list, malformed/error payload; `HerdrPreferences` default-off and missing-field migration; fetch-on-expand's stale-completion guard (`HerdrWorkspaceFetchPlanner.shouldApply`) drops a result for a session removed while the query was in flight | Fixture executable threads the target's executable/environment through `workspace list`/`workspace focus`; nonzero exit reported as failure; tmux target skipped without running anything; `HerdrPreferencesStore` first-launch seed, corrupt-file recovery, immediate persist on toggle. Scoped to the local herdr CLI socket only — confirmed remote machines (`herdr machine list`) aren't reachable this way; see `hyac` |
| Herdr event subscriptions — `s5n3` (see `docs/herdr-events-plan.md`) | `HerdrSocketPath` session-name→socket resolution; `HerdrPaneRegistry` pane-set change detection; `HerdrSocketDecoder` frame classification (ack/pane event/other/malformed) and newline-framing (split-across-reads, multiple-per-read); `HerdrAgentStatus.query`/`paneIDs` decode of real `agent list` JSON | `HerdrEventStreamClient` against a real fixture Unix socket server (`FixtureHerdrSocketServer`): subscribes on connect, triggers on a relevant frame but not an ack, reconnects with the full updated pane set on `updatePaneIDs` (no live patching — confirmed unsupported by the real protocol), reconnects after a server-dropped connection, `stop()` doesn't reconnect. `SessionStore` wiring (client-per-herdr-session lifecycle, debounced trigger → `pollAgentStatus`) isn't independently unit-tested — see `SessionStore`'s existing 0%-coverage rationale; verify via the desktop regression checklist |

Use controlled input time and explicitly delivered asynchronous results for race
tests. Assert final public state and effects represented as data; a fake that merely
counts calls is an interaction mock, not a state-based substitute.

## Priority 2: application behavior and delivery

| Area / issue | Functional core cases | Shell / integration cases |
| --- | --- | --- |
| Profile editing and menus — `ht12` | Edit/cancel validation; stable identity; menu projection; deleted/final-profile policy | Menu and sidebar reflect add/edit/delete; stale menu action cannot launch old command; discovery invalidated; persisted default survives restart |
| Sidebar publication — `nqtc` | Width for expanded/icons/hidden combinations | Actual Combine emissions drive current divider width; hidden-to-icons and icons-to-hidden update immediately; expand via menu/shortcut; preserve surfaces |
| Shortcut rules — `560r` | Exact relevant modifiers; conflict replacement; session-index bounds; legacy migrations; cleared defaults remain cleared; focus/capture routing | Unmatched terminal keys pass through; accepted app action once; atomic rebinding persistence; recording cancelled on context loss; normal field editing and input-method composition |
| Passthrough — related to `560r` | Modifier down/up sequences with supplied timestamps; threshold boundaries; unrelated keys/modifiers interrupt double-tap; disabled toggle; switching toggle resets pending gesture; mode starts off | Real flagsChanged/keyDown routing; enter/exit passthrough; preference persists but runtime mode does not; capture precedence defined; indicator follows emitted state without one-event lag |
| Session switcher — related to `560r`, `eers` | Whitespace/case filtering; empty results; wraparound navigation; query resets highlight; stale/removed selection ID rejected | Open/reopen; Enter/Escape/click; focus restored after dismissal; modifier navigation and marked-text input; no duplicate commit; selected row scrolls into view |
| Effective terminal settings — `1148` | Finite/ranged font size before integer conversion; missing font/theme; consistent fallback; emitted configuration retains keybind clearing | Persist/reload; live font/theme changes update all surfaces and chrome without recreation; invalid saved values cannot crash preference rendering |
| Session/surface lifecycle — `eers` | Close selected/nonselected/last; fallback selection; duplicate close; rejected close; title precedence; rename trimming | Pinned close action accepted/rejected; deferred teardown; one controller; stable surface identity across switching; visible/focused session agrees with selection; owned timers/monitors stop |
| Release/install — `9w8w` | Valid/invalid tag/manual versions; no/partial/full signing field sets with synthetic values | Validate generated bundle/artifact version; workflow branches; staged install failure preserves prior app; use temporary app roots, never production credentials or `/Applications` in tests |
| Unread-session navigation and bell — `apdk` | `UnreadAttentionPolicy.shouldMarkUnread` (deliberately independent of notifyOnAttention/bounceDock -- first observation, focused vs. unfocused/inactive, repeat transitions); `NextUnreadSessionPlanner.next` wraparound (no unread, before/after current, wraps past the end, only-current-itself, stale/missing selection falls back to first in order) | `SessionStore` wiring (mark at the `handleTransition` call site, clear on `select`/`removeSession`/`applicationDidBecomeActive`) and the bell popover aren't independently unit-tested -- same constraint as the rest of `SessionStore`/`SidebarView`; verify via the desktop regression checklist |

## Desktop regression checklist

Run this after changes to terminal hosting, lifecycle, keyboard handling, or live
configuration. Record the macOS/toolchain/app revision and which steps were checked.

1. Launch both a packaged app and the documented plain-shell development mode in
   a desktop session. Check startup responsiveness and useful failure reporting.
2. Create at least three sessions. Produce ongoing output in one; switch using
   sidebar, shortcut, switcher, and status menu. Check surface identity and output
   continuity as well as visible focus.
3. Collapse to icons, change to hidden, then expand. Resize the window and change
   font/theme. Check traffic-light clearance and retained terminal input/output.
4. Exercise normal terminal keys, bound/unbound shortcuts, recording cancellation,
   passthrough toggles, text-field editing, non-US layout, and input-method composition.
5. Close selected/nonselected/last sessions, including natural child exit and rapid
   repeated requests. Relaunch and verify the intended workspace recovery.
6. With disposable agent sessions, check mixed working/waiting status, notification
   toggles, permission denial, click activation, and removal while a poll is pending.

Where automated desktop integration exists, record its results in place of the
equivalent manual step. Keep tests isolated from the user's live sessions.

## Coverage evidence and maintenance

Each behavior change needs a regression that fails for the intended reason before
implementation and passes afterward. Cover normal, empty, invalid, boundary, and
failure/recovery paths where applicable. For asynchronous work, include stale
completion and cancellation paths. For persisted changes, include old data and a
restart, not just encode/decode symmetry.

Report executed test names/suites and commands, remaining gaps, and desktop results.
Collect line/branch coverage after the harness exists to find missed paths; no
percentage target substitutes for these behavioral cases. Avoid tests for trivial
getters, generated project files, exact view trees, and private call ordering.
Update this matrix when a feature adds a new decision or effect boundary.
