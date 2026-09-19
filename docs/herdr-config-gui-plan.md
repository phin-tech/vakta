# Plan: GUI editor for the herdr config

Status: proposal, not started. Implementation follows the RED/GREEN/REFACTOR
gates in [AGENTS.md](../AGENTS.md); this document authorizes none of them.

## Goal

Edit herdr's `config.toml` from a Vakta Preferences pane and from ⌘K, save it,
and have the running herdr pick it up. **The file is the only source of truth**:
Vakta stores no shadow copy of herdr settings (unlike `HerdrPreferences`, which
is Vakta's own JSON). Edits made by hand, by herdr, or by another tool must
show up in the GUI, and GUI saves must not damage anything the GUI does not
understand.

## Facts established (evidence)

- Path: `~/.config/herdr/config.toml`, overridden by `HERDR_CONFIG_PATH`
  (herdr.dev/docs/configuration). `herdr --help` prints the resolved path.
- **Schema authority.** Per the request, the docs
  (herdr.dev/docs/configuration and /docs/config-reference) are the basis of
  truth for the catalog. `herdr --default-config` (374 lines, commented TOML)
  is used only by a drift test that flags divergence, not as the source.
  **Known divergence to rule on:** `ui.toast.delivery` default is `"herdr"` on
  the configuration page but `"off"` on config-reference and in
  `--default-config`. Proposed: follow config-reference/`--default-config`
  (two of three agree), but you decide.
- `herdr config check` (verified in this session with temp files): honors
  `HERDR_CONFIG_PATH`, needs no live server, exits 0 with `config: ok` or **1**
  with `config: issues found` plus a rustc-style diagnostic
  (`TOML parse error at line N, column M`, source excerpt, e.g.
  `unknown variant \`sideways\`, expected \`top\` or \`bottom\``), ending
  `; using defaults`. Limits: it reports only the **first** error, and an
  unknown key (`bogus_key = 1`) was NOT flagged. So `check` proves
  parseability/enum validity, not key-name correctness — key names come from
  our catalog. `herdr config` has only `check` and `reset-keys`; no get/set, so
  a text patcher is required.
- `herdr server reload-config` reloads a running server. Docs: theme, sidebar,
  copy, keybindings are client-side; pane defaults, worktrees, integrations,
  commands are server-side; some keys are startup-only
  (`ui.sidebar_start_collapsed` says "next launch").
- Reference lists ~208 keys in 16 sections (herdr.dev/docs/config-reference).
  `[[keys.command]]` is documented separately (types `popup|pane|shell|
  plugin_action`, `key`, `command`, `description`, `width`, `height`).
- Something other than the user writes this file: the directory holds
  `config.toml.bak-keybind-v2-*`, `bak-dotfiles-*` and `backup-before-cmd-*`
  (herdr migrations, `reset-keys`, possibly its in-app `prefix+s` settings, or
  dotfile tooling). Herdr/others are concurrent writers; the fingerprint check
  must cover them, and we should inspect how herdr itself rewrites the file
  (format preservation) before finalizing the patcher.
- The user's real file is hand-written: comments, a sparse `[keys]` table
  (`switch_workspace = "cmd+1..9"` — a range syntax, not a plain chord), and a
  key (`agent_panel_sort`) users add themselves. A parse-and-reserialize
  writer would destroy comments/ordering. This is the central design risk.
- Vakta today: `HerdrPreferencesView` (one toggle), `PreferencesSection.herdr`,
  ⌘K actions are `PaletteItemKind.action(id:)` dispatched in `App.swift`
  (`"openPreferences"` precedent), persistence goes through
  `PersistedFileStore` (JSON-only, atomic, corrupt-file-preserving). No TOML
  dependency exists in `Package.swift`/`project.yml`.

## Design

### Functional core (pure, in `VaktaCoreTests`)

1. **`HerdrConfigCatalog`** — static typed table of known keys:
   `path` (`ui.toast.delivery`), `kind` (`bool | int(range) | enum([String]) |
   string | path | color | keybinding | stringList | tokenRows | ...`),
   `default`, `group`, `label`, `help`, `applies` (`live | restart | server`).
   Hand-authored from the reference; **not** generated at runtime.
2. **`HerdrConfigDocument`** — value type wrapping the raw file text plus a
   line index: table headers, `key = value` lines, comments. API:
   `value(at:) -> HerdrConfigValue?`, `setting(_ path, to:) -> Document`,
   `unsetting(_ path) -> Document`, `unknownKeys`. **Surgical patching**:
   replace only the value span of an existing line; insert a new key at the end
   of its table (creating `[table]` if absent); "unset" removes the line. All
   other bytes (comments, blank lines, ordering, unknown keys, `[[array]]`
   tables) are untouched. Trailing inline comments on the edited line are kept.
3. **`HerdrConfigFieldValidator`** — per-kind client-side checks (range, enum
   membership, hex/`rgb()`/named colors, non-empty popup command, duplicate
   binding detection within `[keys]`). Advisory only; `herdr config check` is
   the arbiter.
4. **`HerdrConfigSavePlanner`** — decides outcome from inputs
   (`baseFingerprint`, `currentFingerprint`, `checkResult`): `.save`,
   `.conflictExternalEdit`, `.rejectInvalid(diagnostics)`.

TOML value scanning for the patcher is a small, scoped scanner (strings,
bare scalars, arrays, inline tables spanning lines). It only has to find
value spans, not implement TOML. Placement rules: top-level keys (`onboarding`) are inserted before the first
`[table]` header, never appended at EOF; a key is written into its exact table
header if one exists (`[ui.toast]` for `delivery`), never as a dotted key under
`[ui]` when that header exists elsewhere; otherwise the table is created at
EOF. Anything it cannot delimit confidently makes
that key **read-only in the GUI** ("edit in raw file") instead of guessing.

Rejected alternative: a TOML library (e.g. TOMLKit). Adds a dependency to both
SwiftPM and XcodeGen, and round-trip comment/format fidelity would still need
proving against the user's real file. Revisit only if the scanner exceeds
scope.

### Imperative shell (in `VaktaIntegrationTests`, real files + fixture executable)

- **`HerdrConfigLocator`**: resolves path from `HERDR_CONFIG_PATH`, else
  `~/.config/herdr/config.toml`. (Confirm against `herdr --help` output.)
- **`HerdrConfigFile`** (I/O): read text + fingerprint (content hash, not
  mtime alone); write atomically; make timestamped backup
  (`config.toml.bak-vakta-<ts>`) before the first save of a session and keep
  the last N.
- **`HerdrConfigChecker`**: writes candidate text to a temp file and runs
  `HERDR_CONFIG_PATH=<tmp> herdr config check` (exit 1 = invalid; parse the
  `line N, column M` anchor and message) via existing `ProcessRunner`/
  `BoundedProcessRunner` (bounded, minimal env, scrubbed). Parses diagnostics
  into value types. Missing `herdr` binary → distinct outcome, save allowed
  only with explicit "unverified" confirmation.
- **`HerdrConfigReloader`**: `herdr server reload-config` targeted at the
  right server. Local default server only in v1 (same limitation `hyac`
  documents for workspaces). Failure to reload is surfaced, not fatal — the
  file is already saved.
- **`HerdrConfigStore`** (`@MainActor ObservableObject`): holds
  `document`, `baseFingerprint`, dirty set, diagnostics, save state. Watches
  the file (DispatchSource/poll with debounce, owned + stoppable per
  swift-practices; a vnode watch follows the inode, so re-open on
  `.rename`/`.delete` — our own atomic write and herdr's both replace it) and reloads when clean, flags conflict when dirty.
  Stale-async-result guard uses a generation token like `WorkspaceFetchPlanner`.

### Save flow

edit fields → `document.setting` → **Save** → check-on-temp-copy →
(invalid: show diagnostics, do not write) → fingerprint re-check
(external edit: offer reload/overwrite) → backup → atomic write → reload
server → toast result ("Saved · reloaded" / "Saved · restart herdr for: X").
No auto-save on every keystroke: herdr validation is a process spawn and an
invalid intermediate value must never hit disk.

### UI

- Preferences: new **"Herdr Config"** section (keep the existing **Herdr**
  section for Vakta-side options like `showWorkspaces`, to keep the
  "herdr's settings" vs "Vakta's settings" boundary visible). Sub-navigation by
  catalog `group`: General, Terminal, UI & Layout, Notifications & Sound,
  Session, Worktrees & Remote, Advanced, Experimental, Keys, Theme, Sidebar rows,
  Custom commands, Raw. Form rows generated from the catalog (Toggle, Stepper,
  Picker, TextField, color well, path chooser). Each row shows default value,
  a "modified" dot, a reset-to-default (unset) button, and a "restart required"
  badge from `applies`.
- Header shows resolved file path, "Reveal in Finder", Revert, Save.
- Unknown/unparseable keys surface in a read-only "Not managed by this editor"
  list so nothing is silently invisible.
- **Raw** tab: plain monospaced text editor over the same document + same
  check/save pipeline. This is the escape hatch that makes the structured
  editor safe to ship incomplete.
- ⌘K: actions `Edit Herdr Config…` (opens Preferences on the section) and
  `Reload Herdr Config` (runs the reloader), plus optionally drill-in
  "Herdr Config ▸ <group>" using the existing hierarchical-palette scopes.
  Registered via the existing `PaletteItemKind.action(id:)` path.
- Keys editor: reuse Vakta's keybinding recorder for chords, but herdr's
  grammar differs (`prefix+`, `cmd+`, `1..9` ranges, named punctuation
  `minus`), so it needs its own `HerdrKeyChord` parse/format in the core, with
  the raw string as fallback when a value doesn't round-trip.
  Note AGENTS.md: native editor controls keep normal text-entry behavior;
  the recorder must not go through the app key matcher while capturing.

### Phasing (each phase independently shippable, each starts at RED)

1. Core: catalog + `HerdrConfigDocument` patcher + validator + save planner.
   Fixture-based tests, including the user's real file as a golden fixture.
2. Shell: locator, file, checker, reloader, store. Integration tests with a
   fixture `herdr` executable + temp dirs (no real user config, no live server).
3. UI: scalar groups + Raw tab + ⌘K actions. This alone covers ~80% of keys.
4. Keys editor with chord parsing.
5. Theme (name/auto-switch/custom color tokens incl. `light`/`dark` layers).
6. Sidebar rows + `rows_by_agent` (token-row editor with inline style rules)
   and `[[keys.command]]` list editor.

### Catalog drift

herdr adds keys. Two guards: (a) an integration test (skipped, reported as
skipped, when `herdr` is absent) diffs catalog paths against every key/commented
key parsed from `herdr --default-config` and fails on unknown-to-catalog keys;
(b) unknown keys in a user file are preserved and listed, never dropped.

## Test plan (per docs/testing.md; add a row there when implemented)

Core: set/unset/insert-into-existing-table/create-table; comments, blank lines,
CRLF, inline trailing comments, dotted keys (`ui.sound.agents.claude`) vs
`[ui.sound.agents]` tables, quoted keys, multi-line arrays, `[[keys.command]]`
untouched, duplicate keys, key before any table, unset last key in a table,
idempotence (set to current value = byte-identical), golden real-user file
round trip; enum/range/color/int validators; save planner matrix; fingerprint.
Shell: fixture herdr reporting ok/errors/nonzero/timeout/missing; check runs on
temp copy and never touches the live file; invalid → live file bytes unchanged;
external edit between load and save → conflict; backup created; atomic write;
unreadable/absent config (absent → seed empty document, don't create until
first save); reload failure after successful save.
Desktop checklist (unverified in headless CI): Preferences section renders,
palette actions appear and dispatch, file-watch refresh, recorder focus.

## Risks / open questions

1b. **Reload coverage.** Docs say keybindings/theme/sidebar are *client-side*
   and pane defaults/worktrees are server-side; `keys.reload_config` is a client
   action. `herdr server reload-config` may not refresh an attached client for
   `[keys]`/`[theme]`. Unverified; the post-save toast must say only what was
   verified per key group (`applies`), and this needs a hands-on check by you
   (GUI checks are handed to the user here).
1. **Reload targeting.** `reload-config` acts on which server when several
   herdr sessions exist (`--session`, `HERDR_SESSION`, remote profiles)? Need to
   confirm; v1 = default local server only.
2. **Live vs restart per key** is only partially documented. Catalog `applies`
   must be verified per key (empirically via `reload-config` + docs) or shown as
   "unknown"; do not claim "applied" for keys we haven't verified.
3. **Value-span scanner fidelity** on exotic TOML (multiline strings, literal
   strings, escapes in inline tables). Mitigation: read-only fallback + Raw tab.
4. **Overlap with Vakta.** Herdr's `[keys]`/`[ui.toast]`/`[ui.sound]` resemble
   Vakta's own Keybindings/Notifications panes. Keep them separate and label
   clearly; no syncing.
5. **Multi-machine.** Remote herdr machines have their own config; out of scope.
6. Should saves keep unlimited backups or last N? (Proposed: last 5.)
7. Whether herdr's `--default-config` output should be shelled out at runtime to
   show authoritative defaults for the installed version (nice, but adds a
   spawn and a version-skew case) vs only static defaults in the catalog.
   Proposed: static, with the drift test.

## Out of scope

Editing herdr plugins/integrations, `herdr config reset-keys` (could be a later
⌘K action), remote machines' configs, theme previews, importing/exporting
presets.

## Tracking

Kata search (`herdr`) found no existing config-editor issue; related open
work is `vakta#63w2` (backend capability model) — unrelated to this scope.
After approval: one epic, one issue per phase, parent links for containment,
blocked-by only 1→2→3 and 3→4/5/6.
