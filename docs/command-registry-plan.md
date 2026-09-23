# Command registry plan

Status: implemented through GREEN (2026-09-23); REFACTOR pending. Prerequisite for leader-key command discovery
(Spacemacs/Doom style), which will ship behind a Preferences flag, default off.

## Problem

Vakta has two unrelated command namespaces:

| | Chords | ⌘K palette |
| --- | --- | --- |
| Identity | `KeybindingAction` enum (`Keybinding.swift`), 14 cases | String ids in `AppDelegate.paletteActions` (`App.swift`), 18 entries |
| Dispatch | `keybindingMatcher.install { switch action … }` (`App.swift`) | `performPaletteAction(_ id: String)` with `default: break` |
| Availability | none | `multiplexerActionIDs` set + `selectedSessionSupportsActions()` |
| Listing | hand-written `appActions` in `KeybindingsPreferencesView` | hand-written `paletteActions` |

Consequences observed in the current tree:

- Split, zoom, close and rename pane, the workspace actions, stop session, new
  session, toggle file sidebar, open in editor and the herdr-config actions
  cannot be bound to a chord.
- `.nextUnreadSession` has a default chord (⌘U) but is missing from
  `KeybindingsPreferencesView.appActions`, so it cannot be rebound or cleared in
  Preferences. Deriving the list from a registry fixes this.
- A misspelled palette id compiles and silently does nothing (`default: break`).
- The five overlapping commands (toggle sidebar, open Preferences, three font
  sizes) already call identical code on both paths, so merging them changes no
  behavior.

A leader tree would otherwise become a third list to keep in sync.

## Design

### Functional core

**`AppCommand`**: one enum for the app commands currently exposed through
chords or static ⌘K action rows. It replaces `KeybindingAction` and the palette
string ids. Session, workspace and pane navigation rows remain distinct
`PaletteItemKind`s; this slice does not turn every menu or context-menu action
into a command.

- Cases are the union of both lists. Existing `KeybindingAction` case names and
  associated-value shapes are kept **unchanged** (see Persistence).
  New cases: `newSession`, `toggleFileSidebar`, `openInEditor`,
  `splitPaneRight`, `splitPaneDown`, `zoomPane`, `closePane`, `renamePane`,
  `closeWorkspace`, `newWorkspace`, `stopSession`, `editHerdrConfig`,
  `reloadHerdrConfig`.
- Per-command metadata as switch-exhaustive computed properties, so adding a
  case is a compile error until every property is answered. Catalog membership
  remains hand-ordered and must be checked separately when a case is added:
  - `title`: one label shared by the palette, Preferences and (later) which-key.
    Preserve current palette titles for those 18 commands; chord-only
    commands keep their existing titles, except `openSessionSwitcher`, which
    was renamed "Command Palette" (from "Session Switcher").
  - `stableID`: a string (`"splitPaneRight"`, `"selectSession.3"`) for palette
    row ids now and a human-editable leader-tree config later.
  - `scope`: the existing `KeybindingActionScope` (`global` for quit and close
    window, `contextSensitive` for everything else, including all new cases).
  - `paletteRequirement`: `.none | .multiplexerActions`. This preserves the
    current row visibility: all eight actions in `multiplexerActionIDs`,
    **including** New Workspace and Stop Session, require a selected session
    for which `LaunchTargetResolver.supportsActions` is true. Open in Editor
    remains listed even without a selected session, as it is today.
  - `group`: `application | sessions | panes | workspaces | font | herdr`, for
    grouping in Preferences and, later, the leader tree's default groups.
- **`AppCommandCatalog`**: ordered static lists
  - `paletteCommands`: exactly today's 18 static rows, in today's order before
    the existing multiplexer filter is applied. Keep their current IDs and
    titles, including the ellipsis on Rename Pane and Edit Herdr Config.
  - `bindableCommands`: all non-parameterized commands, with
    `selectSession(0...8)` expanded. A persisted `selectSession` with another
    index still decodes as before; the Preferences list only exposes nine rows.
- **`CommandAvailability.isAvailable(_:in:)`**: a pure decision over a
  `CommandContext` snapshot `{ supportsSelectedSessionActions }`, derived in
  the shell from the selected session and `LaunchTargetResolver.supportsActions`.
  It replaces the `multiplexerActionIDs` set for palette visibility and for
  guarding multiplexer command dispatch.

`PaletteItemKind.action(id: String)` becomes `.command(AppCommand)`, and
`PaletteAction` is deleted. `PaletteItemAssembler` takes `[AppCommand]` and uses
`stableID` for `PaletteItem.id` (`"action:<stableID>"`, which keeps today's ids).

### Imperative shell

- **One dispatcher**: `AppDelegate.perform(_ command: AppCommand)`, a single
  exhaustive switch that merges the chord switch and `performPaletteAction`.
  Both `keybindingMatcher.install` and `selectFromSwitcher` call it. Existing
  helpers (`performWorkspacePaneAction`, `confirmStopSelectedSession`,
  `renameFocusedPane`, …) are unchanged. The dispatcher rechecks the current
  context before a multiplexer effect: a palette row can outlive a selection
  change, and chords bypass palette filtering. It is not a new protocol or
  type: it stays in the adapter that owns the effects.
- The palette builds its action rows from `AppCommandCatalog.paletteCommands`
  filtered by `CommandAvailability`, with the capability snapshot taken from
  `sessionStore` and `LaunchTargetResolver`. Existing non-multiplexer rows
  remain visible without a selection.
- `KeybindingsPreferencesView` renders `AppCommandCatalog.bindableCommands`
  grouped by `group`. New commands ship unbound, and `Keybinding.defaults` is
  unchanged.
- Menu items with direct selectors (font size, sidebar) may stay as they are.
  Routing them through `perform` is optional cleanup, not part of this slice.

### Chord on an unavailable command

For example, ⌘\ is bound to Split Pane Right and the selected session is a plain
shell. **Consume the chord and no-op**, consistent with the matcher's current
behavior for bound chords and the palette helpers' silent guards. Falling
through would make the chord's meaning depend on the selected session. This
behavior is part of the proposed acceptance criteria; test it explicitly.

## Persistence

`KeybindingAction`'s synthesized `Codable` writes the case name as the key
(`{"toggleSidebar":{}}`, `{"selectSession":{"_0":2}}`). Renaming the Swift type
does not change the wire format as long as case names and associated-value
labels stay the same. Therefore:

- No file-format change and no `KeybindingFileCodec.currentVersion` bump.
  New commands ship unbound, so there is nothing to migrate.
- **Downgrade**: an older Vakta build that reads a file containing a new case
  fails to decode it. That is `.corrupt`, which falls back to defaults in
  memory **without overwriting the file at startup** under
  `KeybindingStartupPlanner`'s existing policy. Editing a binding in that older
  build can then overwrite the file and lose the newer bindings. Record this
  compatibility limit in the release notes; do not claim a safe round trip
  through an older build.
- No golden-bytes test of the legacy wire format exists today; this slice adds one.

## Testing strategy

### Functional core (`Tests/VaktaCoreTests`)

- `AppCommandCatalogTests`
  - `paletteCommands` equals today's 18 commands in today's order, with the
    same IDs and titles (regression: static palette rows unchanged).
  - `stableID` is unique across `bindableCommands`, including `selectSession(0...8)`.
  - `bindableCommands` contains the union of the existing action cases and
    palette-only commands exactly once, including `.nextUnreadSession`
    (regression for the missing Preferences row). A future enum case still
    requires an explicit catalog update; exhaustive metadata switches alone
    cannot prove that a hand-ordered list contains it.
- `CommandAvailabilityTests` (table-driven)
  - All eight existing multiplexer rows, including `newWorkspace` and
    `stopSession`, are hidden when no selected session supports actions.
  - Those eight are visible when the selected session supports actions.
  - Non-multiplexer rows remain visible with or without a selected session.
- `KeybindingRoutingTests` (extended): every new command is `contextSensitive`;
  quit and close window remain `global`.
- `KeybindingFileCodecTests` (extended)
  - Fixed, pre-change encoded bytes for both legacy enum shapes
    (`{"toggleSidebar":{}}`, `{"selectSession":{"_0":2}}`) inside real
    bindings, plus a complete v7 payload, decode to the same commands. Encode
    the same bindings after the rename and compare the action JSON shape.
  - A binding to a new command round-trips.
  - A file containing an unknown case decodes as `nil` or corrupt, not partially.
- `KeybindingStartupPlannerTests` (extended): a corrupt, unknown-case file
  yields defaults with `shouldPersist == false`.
- `PaletteItemAssemblerTests` / `PaletteNavigationPlannerTests` (updated):
  action rows carry `.command(_)` with `id == "action:<stableID>"`; Enter commits
  `.command`; Tab on a command is `.noOp`.

### Imperative shell (`Tests/VaktaIntegrationTests`)

- `KeybindingPersistenceTests` (temp root)
  - Bind `.splitPaneRight`, reconstruct the `KeybindingMatcher` from the same
    root, and the binding survives the restart.
  - A pre-existing legacy file loads with its bytes preserved on disk until the
    next user edit.
  - A file containing an unknown case is not overwritten at startup.
- `KeybindingMatcherRoutingTests`: a real keyDown for a chord bound to a new
  command is consumed and delivers that command. It falls through while a text
  view is first responder. Pair this with the core availability test and the
  desktop check for the consumed-but-unavailable chord; the matcher alone
  cannot prove the AppDelegate effect guard.

### Desktop checklist (manual; GUI automation unavailable here)

- Each of the 18 palette rows still performs its action.
- The multiplexer rows are still hidden for a plain-shell session.
- In Preferences, the new groups render, ⌘U (Next Unread Session) is now listed
  and rebindable, and a recorded chord for Split Pane Right splits the herdr
  and tmux panes.
- The same chord on a plain shell is consumed without effect.

`docs/testing.md`: add a "Command registry" row under Priority 2 next to
"Shortcut rules — `560r`" when implementation begins. That matrix records
implemented coverage rather than a queue of proposed work.

## Phasing

1. **RED**: publish the Functional Core / Imperative Shell testing strategy,
   then write only failing tests. Start with behavior expressible through
   existing types; tests for the new API may fail to compile because its
   symbols do not exist yet. Report that separately from a behavioral RED.
   Do not add production stubs in this phase. Halt for explicit GREEN approval.
2. **GREEN**: rename `KeybindingAction` to `AppCommand` and add the cases,
   catalog and availability. Switch the palette to `.command`, add the single
   dispatcher with the current-context guard, and derive Preferences from the
   catalog. Remove the replaced `PaletteAction` and `multiplexerActionIDs`
   definitions so no second command list remains. Run tests until the new
   tests pass, then halt for a separate REFACTOR command.
3. **REFACTOR**: optionally route menu selectors through `perform` without
   changing their behavior.

RED verification: run the relevant tests when possible and report the expected
failure; a missing symbol or toolchain failure does not count as behavioral
RED. GREEN verification: run the focused regressions and affected suite, then
`swift test`, `swift build`, and the generated XcodeGen app build because this
touches shared sources. REFACTOR reruns the affected tests and required builds.

## Follow-up: leader keys (implemented through GREEN, 2026-09-23)

- `LeaderKeys.swift` (pure): `LeaderTree.defaultRoot` (leaves are
  `AppCommand`s), `LeaderSequencePlanner.step`, `LeaderHintAssembler`,
  `LeaderSettings` (persisted in `leader.json`; off by default, chord ⌘/).
- `KeybindingMatcher` owns the pending `leaderPath`. Precedence: capture >
  passthrough > pending sequence > leader chord > bindings. The leader chord
  falls through while a text view is focused, just like a contextSensitive
  chord does.
- Unavailable commands are hidden from which-key; a key leading to one is
  consumed and cancels the sequence.
- `LeaderHintPanel.swift`: a non-key child panel along the window's bottom
  edge, shown after 300 ms.
- Preferences → Keybindings → Leader Key: the toggle and chord recording.
- Not yet: a user-editable tree (planned to serialize leaves by `stableID`).
