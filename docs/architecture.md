# Architecture

This is the durable reference for Vakta's cross-cutting invariants. Source
comments point here by name (e.g. "the permanent-AppKit-terminal-host
invariant") instead of a bare "settled design decision #N" -- this file is
what that name resolves to. If you change one of these, update this file in
the same change.

See also: [README.md](../README.md) for build/run/release instructions,
[docs/testing.md](testing.md) for the test coverage plan and desktop
regression checklist, and [docs/swift-practices.md](swift-practices.md) for
Swift-level engineering rules (concurrency, persistence, compatibility), and
[docs/multiplexer-backends.md](multiplexer-backends.md) for the per-backend
capability survey (herdr/tmux/zellij and how to add another).

## Shape of the codebase

Vakta follows a functional-core/imperative-shell split (see
[AGENTS.md](../AGENTS.md)):

- **Core** — pure value types, generally named `*Planner`/`*Resolver`/
  `*Router`/`*Validator` (e.g. `SessionLifecyclePlanner`,
  `TerminalThemeResolver`, `KeybindingRoutingPlanner`,
  `TerminalFontSizeValidator`), though the file a type lives in doesn't
  always match its own name -- e.g. `TerminalFontSizeValidator` is in
  `TerminalSettingsResolver.swift`. No file I/O, process spawning,
  AppKit/Ghostty objects, or shared mutable state. Tested in
  `Tests/VaktaCoreTests` with table-driven input/output cases.
- **Shell** — `ObservableObject` stores (`SessionStore`, `TerminalSettingsStore`,
  `KeybindingMatcher`, ...) and AppKit glue (`App.swift`,
  `TerminalContainer.swift`, `PreferencesWindowController.swift`) that own
  I/O, observable state, and effect execution, calling into the core types
  above for decisions. Tested in `Tests/VaktaIntegrationTests` against real
  temporary files, real subprocesses, real `NSEvent`/`NSWindow`/Combine --
  never mocks.
- **Release tooling** — `scripts/*.sh`, each a standalone, individually
  testable script (`Tests/scripts/test_*.sh`) rather than logic inlined into
  `.github/workflows/release.yml`.

## Architectural invariants

### Single shared terminal controller

One `TerminalController` (wrapping one `ghostty_app_t`) exists for the whole
process, owned by `SessionStore` and handed to every `Session`. Sessions
never each get their own controller.

**Why:** one controller means a config/theme change (font, theme, keybind
clearing) applies to every live surface through a single path, with no risk
of two controllers' copies of that state drifting apart. It also matches an
actual constraint in the pinned dependency: libghostty-spm's own test
harness comment notes "One Ghostty app/surface at a time. Parallel
`ghostty_app_new` aborts." (`Tests/GhosttyKitTest/GhosttySurfaceHarness.swift`
in the resolved checkout) -- a second concurrent `ghostty_app_t` isn't just
undesirable, it's unsupported.

**Where:** `SessionStore.swift`.

### Permanent AppKit terminal host

Every session's terminal surface (`AppTerminalView`, via
`TerminalHostContainerView.addSession`) is added once and stays a subview,
alive, for the session's entire lifetime. Switching the visible session
flips `isHidden` + `setSurfaceVisible(_:)` on exactly two views -- it never
adds, removes, or recreates a surface. Only `removeSession(_:)`, called when
a session actually closes, tears one down. The container itself is a
permanent, direct subview of the window's `NSSplitView` content view;
SwiftUI never owns, wraps, or is asked to diff it.

**Why:** SwiftUI's declarative diffing does not guarantee a view (or an
`NSViewRepresentable`'s wrapped view) is created exactly once over its
logical lifetime -- a diff can recreate or tear one down for reasons
unrelated to session state. Recreating a terminal surface kills its live
PTY/child process; a sidebar-selection-triggered SwiftUI diff must never be
able to do that.

**Where:** `TerminalContainer.swift`, `App.swift` (window construction),
`SessionStore.swift` (`hostContainer`).

`TerminalContainerRepresentable`, an `NSViewRepresentable` bridge to a
*pre-existing* container, was removed (see git log for this file) after
confirming it had zero callers -- `App.swift` hosts the container directly
as a permanent AppKit subview and never needed the bridge. If a future
layout genuinely needs the container reachable from inside a larger
SwiftUI-only view tree, re-add a bridge that takes the container from
outside rather than constructing it, for the same reason described above.

### Keybindings routed through the matcher, not menu key equivalents

Every app `NSMenuItem` Vakta creates ships with an empty `keyEquivalent`.
Configurable app shortcuts (session select, toggle sidebar, open
preferences, open switcher, quit) are exclusively handled by
`KeybindingMatcher`, never by a menu key equivalent. `SessionStore` also
always emits `keybind = clear` when building libghostty's terminal config,
even on a font-only change (`setTerminalConfiguration` replaces the whole
config rather than merging it), so no built-in Ghostty binding can compete
with the matcher either.

**Why:** an `NSMenuItem` key equivalent is handled by AppKit's menu
system before a key event ever reaches a local `NSEvent` monitor or the
terminal surface -- if any menu item carried one, that keystroke could
never reach herdr/the terminal, defeating "flawless terminal passthrough"
for that key regardless of what the user binds in Preferences.

**Where:** `App.swift` (menu construction), `Keybinding.swift`
(`Keybinding.defaults` doc comment), `SessionStore.swift`
(`configureBuilder`).

### The matcher runs in front of every surface

`KeybindingMatcher` installs one local `NSEvent` monitor
(`.keyDown`/`.flagsChanged`) for the whole app. Per Apple's documented event
dispatch order, a local monitor's handler runs before the event reaches the
key window's `performKeyEquivalent:`/`keyDown:` at all -- strictly before
any surface, including a terminal view, a Preferences text field, or the
profile editor. It consumes a matched, in-context binding (returns `nil`)
or lets the event fall through unchanged. The Preferences "record a chord"
flow (`KeybindingsPreferencesView.startRecording`) deliberately reuses this
same monitor via `captureNext` instead of installing a second one, since a
second local monitor would be shadowed by this one anyway.

Because the monitor runs in front of everything, it must not blindly steal
a chord from whatever the user is doing elsewhere -- see
`KeybindingRoutingPlanner`/`SessionSwitcherKeyRouter`
(`Sources/Vakta/KeybindingRouting.swift`) for how matching now also depends
on focus context (a text-editing first responder,
an in-progress IME composition) rather than the chord alone.

**Where:** `KeybindingMatcher.swift`, `KeybindingsPreferencesView.swift`,
`SessionStore.swift` (`selectSession(at:)`).
