# Plan: GitHub PR Extension

Status: **implemented 2026-10-03 on branch `extensions` (`vakta#szqg`); desktop checks pending (testing.md step 11).** The built-in PR status is gone. Builds on the Extensions
platform ([extensions-plan.md](extensions-plan.md)); vocabulary in
[CONTEXT.md](../CONTEXT.md).

## Goal

Move GitHub pull request status out of Vakta into a Built-in Extension, as
a clean break: when it lands, the built-in `gh` PR code (status bar
segments, PR list, the "Open Pull Request" / "Show Pull Requests" commands,
their polling) is deleted. The Extension matches what the built-in showed and
adds a panel, badges, actions and ⌘K Commands.

## Decisions (grilled 2026-10-03)

| # | Decision |
|---|---|
| 1, 11 | Replace the built-in outright, no transition or handoff. If the Extension is off or failed, there is no PR status. |
| 2 | Status Items become **Status Segments**: text, SF Symbol, semantic tint (`success`/`warning`/`failure`/`neutral`), tooltip, optional click (Callback or URL), optional Popover. A Status Item is `leading` (beside the branch) or `trailing` (right side). |
| 3 | Attention: a segment can carry `attention: true` (Vakta peeks an Auto-hide bar when it turns on), and a new `notify` message (title, body, Session Key) goes through Vakta's attention path, obeying notification settings plus a per-Extension switch. |
| 4 | GitHub GraphQL directly, one batched query per refresh, token from `gh auth token` (refetched after a 401); `gh` CLI as the fallback. |
| 5 | Tiered polling: focused repo 30 s, other Sessions' PRs 3 min, PRs with pending checks 15 s, immediately on focus change / `refresh` / after an action; back off near the rate limit; intervals in `config.json`. |
| 6 | **Pane Contexts**, opt-in (`"contexts": "panes"` in the manifest): every pane's id, Workspace, cwd, git root, branch, focus. Reuses the pane data Vakta already gathers. |
| 7 | **Built-in Extension**: shipped in `Vakta.app/Contents/Extensions/github`, linked automatically, trusted by the app's signature, can be disabled but not unlinked. |
| 8 | Panel View "Pull Requests": PRs for branches open in any pane, grouped by repo, focused repo first. A repo-wide inbox is later work. |
| 9 | Actions (no merge in v1): open, check out in a new pane, re-run failed checks, fix with an agent (configurable command, like Kata's Start), copy link, mark ready / convert to draft. |
| 10 | **Commands**: Extensions push ⌘K Commands live (`commands/set`); a Command exists only while it applies and runs a Callback. |
| — | Found while building: a Status Segment may override its item's placement (PR status needs a leading part and a trailing summary); a `copy_text` Effect for Copy Link; saved key bindings for the removed PR commands are dropped, while other unknown commands still keep the file untouched. |
| 12 | Session Badge: the focused pane's PR (`#42` + tinted state), else the Session's worst-state PR; its Popover lists the Session's PRs. Badges gain the semantic tint. |
| — | Defaults taken without a question: the app's own PR commands are removed (stale key bindings dropped by migration); per-Extension notification switch, on by default; code in `extensions/github` on `VaktaExtensionKit`. |

## Protocol additions (`vakta_extension_api` stays 1; all additive)

- `status/set` gains `segments` and `placement`; the old single `text` form
  still decodes as one neutral segment, so Kata keeps working.
- `badge/set` gains `tint`.
- New Extension → host notifications: `notify {title, body?, sessionKey?}`,
  `commands/set {commands: [{id, title, symbol?, callback, payload?}]}`.
- Extension Context gains `panes: [PaneContext]?` (only when opted in).
- Manifest gains `"contexts": "sessions" | "panes"`.

## Slices

1. Protocol kit + fixtures for segments, tints, notify, commands, panes.
2. Status Segments in the status bar (placement, tint, click, popovers,
   attention peek), Status Items migrated; notify through the attention path
   with the per-Extension switch.
3. Commands in ⌘K.
4. Pane Contexts (opt-in).
5. Built-in Extensions: bundle discovery (`Contents/Extensions`, repo
   `extensions/` under `swift run`), trust by signature, "Built in" in
   Preferences, disable-not-unlink; Xcode build phase that builds and copies
   the GitHub Extension.
6. GitHub Extension core: GraphQL query + parsing, `gh auth token`, `gh`
   fallback, polling tiers with backoff, cache.
7. GitHub status: branch PR segment with checks Popover, all-PRs trailing
   segment with grouped Popover, attention and notify on transitions.
8. GitHub panel, actions and Commands.
9. GitHub Session Badges.
10. Delete the built-in PR status (clean break), including its commands,
    tests and docs; update the coverage plan and desktop checklist.
