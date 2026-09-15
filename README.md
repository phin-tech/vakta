# Vakta

Vakta is a native macOS terminal whose one job is to open **herdr** sessions
(herdr is a terminal multiplexer, spawned as a CLI process) with a sidebar to
switch between multiple sessions. Terminal rendering is done by **libghostty**
via the prebuilt Swift package `Lakr233/libghostty-spm`.

This repository is a **skeleton**: a compiling foundation with a clear
structure and explicit `TODO(verify)` markers, not a finished app. It is a
Swift Package Manager executable (`swift build` / `swift run`), not yet an
Xcode project or a signed `.app` bundle — see "Build & run" below.

## Settled design decisions

These were fixed before implementation and are **not** open for
redesign here; each is annotated with how it maps onto the actual, verified
`libghostty-spm` API (see "How this was verified" below).

1. **Terminal core: libghostty via `Lakr233/libghostty-spm`.** Pinned to the
   exact tag `1.6.20260909` (see "Pinned dependency" below). Not building
   Zig from source; the prebuilt XCFramework binary target only.
2. **Model: one `ghostty_app_t` per process, one `ghostty_surface_t` per
   session.** `SessionStore` (`Sources/Vakta/SessionStore.swift`) owns a
   single shared `TerminalController` (which owns the one `ghostty_app_t`)
   and hands it to every `Session` (`Sources/Vakta/Session.swift`), each of
   which owns its own `TerminalViewState` / eventual `ghostty_surface_t`.
3. **PTY: libghostty owns it.** Every session's `TerminalSurfaceOptions` sets
   `backend: .exec` (the wrapper's default) and `command: "herdr"`; libghostty
   spawns and owns the pty and the child process. Vakta contains no
   `posix_openpt`/`fork` code anywhere.
4. **Sidebar switching never tears down a surface.** `TerminalHostContainerView`
   (`Sources/Vakta/TerminalContainer.swift`) is a plain `NSView` that keeps
   every session's `AppTerminalView` as a permanent subview; switching
   sessions only toggles `isHidden` + `setSurfaceVisible(_:)` on two views
   and reassigns first responder. A surface is destroyed only when its
   session is actually removed (session closed / herdr exited), by dropping
   the view — see the type's doc comment for the exact deinit chain.
   **`Vakta/App.swift` makes this container a direct subview of an
   `NSSplitView` that is the window's content view** — SwiftUI never wraps
   or owns it, so the risk of a SwiftUI diff recreating/tearing down the
   `NSViewRepresentable` (which would kill every live surface) does not
   arise. See the "SwiftUI ownership" note below.
5. **Key passthrough.** The shared `TerminalController` is constructed with
   `keybind = clear` (via `TerminalConfiguration.Builder.withCustom`, see
   "Config loading" below), which removes every libghostty default binding.
   The app's `NSMenu` (`Vakta/App.swift`) has **no `keyEquivalent`s** on any
   item, since a menu key equivalent would swallow the key before it ever
   reaches the responder chain.
6. **App-level session-switch chord.** Default `Ctrl+Shift+1…9`, stored as
   (modifier mask, physical key code) pairs in Vakta's own `Keybinding`
   type (`Sources/Vakta/Keybinding.swift`) — never in ghostty's config,
   since "switch to session N" has no meaning to libghostty.
   `KeybindingMatcher` (`Sources/Vakta/KeybindingMatcher.swift`) installs a
   **local `NSEvent` monitor** for `.keyDown`, which Apple documents as
   running before the event is dispatched to the key window's responder
   chain — i.e. strictly before the focused `AppTerminalView`, and therefore
   before libghostty's key path and herdr. Consume-on-match (return `nil`);
   otherwise return the event unchanged so it falls through. Hyper is simply
   `[.control, .option, .shift, .command]` together — there is no dedicated
   case for it anywhere in `Keybinding`.

## Session profiles

Each session is created from a `Profile` (`Sources/Vakta/Profile.swift`) rather
than a hardcoded command, so the base command, working directory, and
environment are all data:

- `name`, `command` (base command spawned in the pty), `workingDirectory`,
  `environment` (variables to **set** — additive), `scrubbedEnvironmentKeys`
  (variables to **remove**), `waitAfterCommand`.
- Built-ins: `Profile.herdr` (the default), `Profile.tmux`, and `Profile.shell`
  (a login shell, handy where a multiplexer isn't installed).
  `SessionStore.profiles` seeds them and drives the "New Session" profile menu
  in both the sidebar and the app menu.
- **Renaming:** a session's name is `Session.customName`, set from the sidebar
  row's "Rename…" context-menu item (inline `TextField`, Enter commits, Esc
  cancels). It's `@Published`, so the row updates live. Resolution order in
  `Session.displayTitle` is: user rename → live shell OSC title → profile name.
- **Multiplexer nesting applies to tmux too:** `Profile.tmux` scrubs `TMUX` /
  `TMUX_PANE` exactly as `.herdr` scrubs `HERDR_*` — tmux refuses to start
  nested when those are inherited ("sessions should be nested with care, unset
  $TMUX to force").
- **Persistence:** profiles are saved to
  `~/Library/Application Support/Vakta/profiles.json` (`ProfilePersistence`) on
  every change and loaded on launch; the first launch seeds and saves the
  built-ins. `VAKTA_TERMINAL_COMMAND` is applied per-spawn in
  `createSession`, never written into `profiles`, so the dev override can't
  leak into the saved file. (Session *rename* is in-memory only — sessions are
  live processes and don't survive a restart.)
- **Editor modal:** `ProfileEditorView` (`Sources/Vakta/ProfileEditorView.swift`)
  is a SwiftUI sheet for creating/editing a profile — name, command, working
  directory, environment (set as `KEY=VALUE` lines, clear as one-name-per-line
  → `scrubbedEnvironmentKeys`), and "keep terminal open after exit"
  (`waitAfterCommand`). Opened from the sidebar's "New Session" menu: each
  profile is a submenu with **New Session** / **Edit Profile…**, plus a
  **New Profile…** item at the bottom. Save upserts via
  `SessionStore.upsertProfile`; a newly created profile opens a session
  immediately; editing an existing one offers Delete
  (`SessionStore.deleteProfile`). It edits a working copy, so Cancel/Esc
  discards.

### The herdr nesting scrub

herdr refuses a nested launch by default — *"nested herdr is disabled by
default … recursive descent denied"* — which is triggered when Vakta is itself
launched from **inside** a herdr session (a herdr shell, a terminal that is a
herdr pane, this Claude Code session, etc.), because the child inherits
`HERDR_ENV` / `HERDR_SOCKET_PATH` / `HERDR_WORKSPACE_ID` / `HERDR_TAB_ID` /
`HERDR_PANE_ID`.

libghostty's surface `envVars` is **additive-only** (it documents adding to,
never removing from, the inherited environment), and the spawned child inherits
Vakta's *own* process environment. So "remove a variable" can't be done
per-surface — it's implemented by `unsetenv()` on Vakta's process
(`Profile.applyEnvironmentScrub()`, called from `SessionStore.createSession`
before the surface spawns). That is process-global by nature: once scrubbed the
key is gone for every later session too, which is exactly right — Vakta is a
herdr *host* and should never look nested to anything it spawns.

Verified empirically: launching the binary with `env -u HERDR_ENV -u
HERDR_SOCKET_PATH … Vakta` spawns herdr cleanly (a real `login … exec -l herdr`
child, no nested error); the in-process `unsetenv` scrub is the functional
equivalent applied from inside the app.

## Building and running the app

Vakta is an Xcode application target defined by a checked-in
[`project.yml`](project.yml) (via [XcodeGen](https://github.com/yonaskolb/XcodeGen)),
alongside the `Package.swift` that keeps `swift build` working for quick
iteration. To produce a double-clickable `.app`:

```sh
brew install xcodegen        # once
xcodegen generate            # regenerates Vakta.xcodeproj from project.yml
xcodebuild -project Vakta.xcodeproj -scheme Vakta -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Vakta.app
```

The app is **not sandboxed** (it spawns herdr/tmux/ssh children, which the App
Sandbox forbids) and enables the **hardened runtime** (required for
notarization; it does not block spawning). Local builds sign ad-hoc.

**Distribution** (Developer ID, notarized — needs the paid Apple Developer
Program): archive and sign with your Developer ID identity + team, then
notarize:

```sh
xcodebuild ... CODE_SIGN_IDENTITY="Developer ID Application: <you>" DEVELOPMENT_TEAM=<TEAMID>
xcrun notarytool submit Vakta.zip --apple-id <you> --team-id <TEAMID> --password <app-specific-pw> --wait
xcrun stapler staple Vakta.app
```

The libghostty-spm xcframework is **arm64-only**, so the app is Apple Silicon
only.

### Releasing (CI/CD)

Cutting a release is just pushing a version tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

`.github/workflows/release.yml` (GitHub Actions, `macos-15` Apple-Silicon
runner) then generates the project, builds Release, packages a `.dmg` (app +
`/Applications` symlink), and attaches it to an auto-created GitHub Release.
`.github/workflows/ci.yml` builds on every push/PR to `main` so breakage is
caught before tagging.

For **signed + notarized** DMGs, set these repo secrets (Settings → Secrets →
Actions); without them the job still ships an ad-hoc DMG that runs locally but
trips Gatekeeper elsewhere:

| Secret | What |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of your *Developer ID Application* `.p12` |
| `MACOS_CERTIFICATE_PWD` | password for that `.p12` |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: You (TEAMID)` |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_TEAM_ID` | 10-char team id |
| `APPLE_APP_PASSWORD` | app-specific password for `notarytool` |

### Why it must render in a real GPU context

libghostty renders with Metal and dereferences its rendering context without a
nil check, so `ghostty_surface_new` segfaults with no usable context. Running
as an `.app` (LaunchServices) gives a proper session. There is a startup guard
(`!NSScreen.screens.isEmpty && MTLCreateSystemDefaultDevice() != nil`) as a
backstop for a truly headless launch, but note it does **not** catch every
case — those APIs succeed over SSH when a console user is logged in.

> Historical note: an earlier `ghostty_surface_new` crash was misattributed to
> SSH/no-display. The real cause was `unsetenv()` (the old env scrub) mutating
> the process `environ` that libghostty walks while building the child
> environment. See "Environment scrub" below.

## Sessions, persistence, and re-attach

herdr and tmux are client/server, so real continuity is **re-attaching** to the
still-running server session, not saving a dead terminal:

- Each session has a stable multiplexer name (`vakta-<8 hex>`, `Session.sessionName`),
  substituted for `{name}` in the profile's arguments — e.g. the herdr profile
  runs `herdr --session vakta-abc12345`, tmux runs `tmux new-session -A -s …`.
- The open-session list is persisted to
  `~/Library/Application Support/Vakta/workspace.json` (`WorkspacePersistence`):
  profile id + session name + rename, saved on every create/close/rename.
- On launch, `SessionStore` restores one session per record, each re-running the
  same attach-or-create command, so it reconnects to the live server session.
  Verified: relaunch reuses the same `--session vakta-…` name and the server
  session count does not grow. First launch (no file) opens one default session.

### Arguments and remote sessions

`Profile.arguments` is a free-form shell-style string appended after `command`,
with `{name}` substituted. This covers remote sessions too — e.g. a profile
with command `herdr` and arguments `--remote me@host --session {name}`. The
editor modal has an Arguments field for exactly this.

### Environment scrub (herdr/tmux nesting)

herdr and tmux refuse to start nested when their `HERDR_*` / `TMUX` variables
are inherited (which happens when Vakta is launched from inside one). The scrub
is applied **in the child** by prefixing the command with `env -u KEY …`
(`Profile.resolvedCommand`) — Vakta never calls `unsetenv()` on its own process,
because mutating `environ` crashes libghostty (see the historical note above).

## License

MIT — see [LICENSE](LICENSE). Vakta embeds
[libghostty-spm](https://github.com/Lakr233/libghostty-spm) (MIT), which wraps
Ghostty's terminal core.

## Runtime callbacks — how the six map onto what was actually found

The task's brief describes wiring `ghostty_runtime_config_s`'s six raw C
callbacks (`wakeup`, `action`, `clipboard_read`/`confirm`/`write`,
`close_surface`) directly. **Reading the resolved `libghostty-spm` checkout
showed these are already wired, internally, by the wrapper** —
`TerminalController.createApp()` in
`.build/checkouts/libghostty-spm/Sources/GhosttyTerminal/Controller/TerminalController+Config.swift`
sets all six on the one `ghostty_app_t`, dispatches `wakeup` to the main
thread and calls `action` synchronously via `MainActor.assumeIsolated`
exactly as the brief describes, and re-publishes the results through
`TerminalSurfaceViewDelegate` sub-protocols that `TerminalViewState` already
conforms to. Per the task's own instruction to prefer the wrapper's
provided types where they already cover the requirement, Vakta does **not**
duplicate this wiring — it consumes it:

| Requirement | Wrapper surface Vakta actually uses |
| --- | --- |
| `wakeup_cb` (arbitrary thread → main) | Internal; not host-visible. |
| `action_cb` — set-title | `TerminalViewState.title` (`@Published`), read by `SidebarView`'s row. |
| `action_cb` — OSC 7 cwd | `TerminalViewState.workingDirectory` (`@Published`, unused by the UI yet — optional per the brief). |
| `action_cb` — bell / desktop notification / command-finished / scrollbar / progress / open-url / mouse-shape | Exposed as further `TerminalSurfaceViewDelegate` sub-protocols (see `TerminalSurfaceViewDelegate.swift`); not consumed by this skeleton beyond title/close. |
| `close_surface_cb` — close-surface / child-exited | `TerminalViewState.onClose: ((Bool) -> Void)?`, wired in `SessionStore.createSession()` to remove the session row. The `Bool` (`processAlive`) is documented in the wrapper's own source as a hint from what libghostty observed on the pty side, not a verified exit code — Vakta treats it exactly as a hint (it only ever triggers row removal, never anything exit-code-sensitive). |

`TerminalCallbacks.action` (the same file) returns `false` for every action
tag except `GHOSTTY_ACTION_OPEN_URL`, and only then when a
`TerminalSurfaceOpenURLDelegate` is attached — satisfying decision #5's "the
action callback returns `false` for unhandled keys so they reach the PTY"
without Vakta writing any of that logic itself.
| `clipboard_read`/`confirm`/`write` | Fully internal; `TerminalViewState.onClipboardConfirmationRequest` exists for a host that wants to add its own confirmation UI. Not wired in this skeleton (left `nil`, which the wrapper documents as "deny a program's read/write, allow a user-initiated paste"). |

The exact list of `ghostty_action_*` tags the wrapper's internal callback
bridge handles was confirmed by reading
`.build/checkouts/libghostty-spm/Sources/GhosttyTerminal/InMemory/TerminalCallbackBridge.swift`:
`SET_TITLE`, `CELL_SIZE`, `RING_BELL`, `RENDER`, `CONFIG_CHANGE`,
`PROGRESS_REPORT`, `COMMAND_FINISHED`, `DESKTOP_NOTIFICATION`, `OPEN_URL`,
`MOUSE_SHAPE`, `MOUSE_OVER_LINK`, `PWD`, `SCROLLBAR`. Close-surface is a
separate runtime callback (`close_surface_cb`), not part of this action
bus, confirmed the same way.

**No raw `GhosttyKit` C call appears anywhere in Vakta's own code.** Every
line of Vakta's terminal-facing code is written against the public
`GhosttyTerminal` Swift API, read directly from the resolved package
checkout rather than guessed.

## SwiftUI ownership of the terminal container

The task's suggested file, `TerminalContainer.swift`, describes "an
AppKit-owned persistent container + `NSViewRepresentable` bridge". Both
exist in that file:

- `TerminalHostContainerView` — the actual AppKit container (an `NSView`).
- `TerminalContainerRepresentable` — an `NSViewRepresentable` bridge to a
  container instance supplied from *outside* (it never creates one itself).

**`Vakta/App.swift` does not use the representable.** It instead makes
`TerminalHostContainerView` a direct, permanent subview of an `NSSplitView`
that is the window's `contentView`, alongside an `NSHostingView` for
`SidebarView`. SwiftUI therefore never owns the terminal container at all.
This was a deliberate choice, not a redesign of decision #4: an
`NSViewRepresentable`'s `makeNSView`/`dismantleNSView` lifecycle is driven by
SwiftUI's own diffing, which is not guaranteed to run exactly once over the
view's logical lifetime — using it as the actual embedding mechanism would
reintroduce exactly the "SwiftUI rebuild kills the surface" failure mode
decision #4 exists to rule out. The representable is kept in the file for a
host that genuinely needs the container reachable from inside a larger
SwiftUI-only layout later.

## Config loading

Rather than a bundled `ghostty.conf` resource file, the shared
`TerminalController` is built with `TerminalConfiguration`'s builder escape
hatch:

```swift
controller = TerminalController(theme: theme) { builder in
    builder.withCustom("keybind", "clear")
}
```

`TerminalConfigCommand.custom(key:value:)` renders exactly `keybind = clear`
(verified by reading `TerminalConfiguration.swift`'s `renderedLine`), which
`TerminalController` then writes to a temp file and loads via
`ghostty_config_load_file` — the same path a bundled resource file would
have taken, without needing SPM resource bundling or `Bundle.module` lookup
for a single line of config.

## Pinned dependency

```swift
.package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260909")
```

`1.6.20260909` is the newest non-prerelease tag on the repository as of
writing (`gh api repos/Lakr233/libghostty-spm/releases`), on the same
`<major.minor>.<UTC YYYYMMDD>` weekly-release track the task's example
(`1.5.<YYYYMMDD>`) describes — `1.5.20260906` and `1.5.20260903` are the
immediately preceding releases on that same track. `exact:` (not `from:`) is
used because the embedding C API is explicitly documented upstream as
unstable, per the task brief.

Resolved products used: `GhosttyKit` (declared as a dependency, satisfying
the task's product list, but not referenced directly by any Vakta source
file — see above), `GhosttyTerminal`, `GhosttyTheme` (used minimally: a
single `GhosttyThemeCatalog.theme(named:)` lookup in `SessionStore.init()`
for the initial color theme, falling back to the wrapper's own default).

## Build & run

```sh
swift build
swift run Vakta
```

**Run it from the Mac's own display, not over SSH.** libghostty renders with
Metal and dereferences its rendering context without a nil check, so
`ghostty_surface_new` segfaults when launched with no logged-in desktop session
(e.g. from an SSH shell). `applicationDidFinishLaunching` guards on
`!NSScreen.screens.isEmpty && MTLCreateSystemDefaultDevice() != nil` and shows
an alert + quits instead of crashing — but the app still needs a real display
session to actually run.

There is no bundled `herdr` in this environment, so for a build-only /
UI-smoke-test run without it installed:

```sh
VAKTA_TERMINAL_COMMAND=/bin/zsh swift run Vakta
```

This launches a plain `NSApplication` (no Info.plist, no app icon — a
`.app` bundle / Xcode project is future work) with a window: a SwiftUI
sidebar on the left, the AppKit terminal container on the right. `+` in the
sidebar (or the "Session ▸ New Session" menu item) opens another session;
`Ctrl+Shift+1`…`9` switches between the first nine.

## File-by-file summary

- `Package.swift` — executable target `Vakta`, depends on `GhosttyKit`,
  `GhosttyTerminal`, `GhosttyTheme` from the pinned `libghostty-spm` tag.
- `Sources/Vakta/App.swift` — `NSApplication` bootstrap (`@main enum
  VaktaMain`), `AppDelegate` builds the window (`NSSplitView` of
  `NSHostingView(SidebarView)` + `SessionStore.hostContainer`) and the main
  menu (no key equivalents), installs `KeybindingMatcher`.
- `Sources/Vakta/Session.swift` — one herdr session: a `TerminalController`
  reference (shared), `TerminalSurfaceOptions` (backend `.exec`, `command`),
  and a `TerminalViewState`.
- `Sources/Vakta/SessionStore.swift` — `ObservableObject` owning the session
  list, selection, the shared `TerminalController`, and
  `TerminalHostContainerView`; `createSession`/`requestClose`/`select`/
  `selectSession(at:)`.
- `Sources/Vakta/TerminalContainer.swift` — `TerminalHostContainerView` (the
  AppKit-owned persistent surface host) and `TerminalContainerRepresentable`
  (unused-by-default SwiftUI bridge, see above).
- `Sources/Vakta/SidebarView.swift` — SwiftUI sidebar chrome only; observes
  each session's `TerminalViewState` for the row label/focus dot.
- `Sources/Vakta/Keybinding.swift` — Vakta's own (modifier mask, physical
  key code, session index) chord type; `Keybinding.defaults` = Ctrl+Shift+1…9.
- `Sources/Vakta/KeybindingMatcher.swift` — local `NSEvent.keyDown` monitor;
  consume-on-match, else fall through.
- `.gitignore` — `.build/`, `.swiftpm/`, Xcode artifacts, `.DS_Store`.

## `TODO(verify)` / unverified assumptions

Everything about the `GhosttyTerminal` public API used here was read
directly from `.build/checkouts/libghostty-spm/Sources/GhosttyTerminal` (not
guessed). What's left unverified:

1. **`TerminalSurfaceOptions.command` PATH resolution — RESOLVED empirically.**
   Ran the built executable with `VAKTA_TERMINAL_COMMAND=zsh` (a bare name,
   no path) and inspected the process tree:
   `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l zsh"`
   appeared as a real child process of Vakta. libghostty threads `command`
   through a login shell's `exec -l <command>`, so a bare, `$PATH`-resolvable
   name works — `herdr` does not need to be an absolute path as long as it's
   on `$PATH`. (Also confirms, independent of decision #3's design intent,
   that the surface → pty → exec path in `SessionStore`/`TerminalContainer`
   genuinely works end-to-end, not just "compiles".)
2. **`"close_surface"` binding-action name** (`SessionStore.requestClose`).
   `performBindingAction` forwards the string to
   `ghostty_surface_binding_action`; the table of valid action names lives
   in upstream Ghostty's Zig source, not in this Swift wrapper's checkout,
   so this name is presumed by convention (it is the customary action bound
   to closing a pane/tab in upstream Ghostty's own default keymap) rather
   than re-derived from source the way everything else in this project was.
3. **`Keybinding`'s digit key codes** (`kVK_ANSI_1`…`kVK_ANSI_9` = 18, 19,
   20, 21, 23, 22, 26, 28, 25) are physical/ANSI-layout codes. Verified
   against the well-known, stable Carbon `HIToolbox` constant table (these
   are platform constants, not part of libghostty's unstable API), but not
   verified on real non-US/ISO keyboard hardware.
4. **`waitAfterCommand` default.** Left `nil` (untouched) on every session's
   `TerminalSurfaceOptions`, meaning whatever `ghostty_surface_config_new()`
   defaults to is what determines whether `terminalDidClose` fires
   immediately when herdr exits or only after some further action. Not
   exercised at runtime (no `herdr` binary available here to observe exit
   behavior against); the doc comment on the option only describes what the
   flag does, not its default.
5. **Ghostty config directive syntax beyond `keybind = clear`.** Only this
   one directive was needed and its exact rendering (`"\(key) = \(value)"`)
   was confirmed by reading `TerminalConfiguration.swift` — but the set of
   *valid* directive names/values otherwise (font, colors, etc.) was not
   exhaustively checked against upstream Ghostty's config schema; the
   `TerminalConfiguration.Builder` convenience methods used elsewhere
   (`withFontSize`, etc., not currently used by Vakta beyond the shipped
   `TerminalConfiguration.default`/theme path) are trusted as-is.
6. **No keybinding persistence yet.** `Keybinding` is `Codable` (manually,
   since `NSEvent.ModifierFlags` isn't `Codable` on its own — encoded as its
   raw `UInt`) so a settings screen can serialize it later, but nothing
   currently loads or saves it: `KeybindingMatcher.bindings` is seeded from
   `Keybinding.defaults` fresh on every launch. A real rebinding UI and a
   config file location (e.g. `~/Library/Application Support/Vakta/`) are
   both still open.
7. **Local `NSEvent` monitor vs. `performKeyEquivalent` ordering under all
   circumstances.** The chosen approach (a local monitor) is documented by
   Apple to run before an event's normal dispatch, and this was smoke-tested
   only by confirming the app launches and stays running (no `herdr`
   binary was available to verify an actual keystroke reaches a live pty in
   this environment); the *exact* interaction with `AppTerminalView`'s own
   `keyDown`/IME handling under real keyboard input was not exercised
   end-to-end.

## Build status

`swift build` succeeds with **zero warnings and zero errors** (Swift 6.2 /
`swift-tools-version 5.10`, resolved against `libghostty-spm` `1.6.20260909`
+ its `MSDisplayLink` `2.2.0` dependency).

The built executable (`.build/debug/Vakta`) was launched directly (no
`herdr` in this environment, so `VAKTA_TERMINAL_COMMAND=zsh`/`/bin/zsh`) and
verified beyond "it doesn't crash":

- It stays running with no stderr/stdout output (config accepted — a
  rejected `keybind = clear` config would have logged via `NSLog`).
- **Its process tree shows a real pty child**:
  `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l zsh"`
  as a direct child of the Vakta process — i.e. `TerminalHostContainerView.addSession`
  → the wrapper's lazy surface build on window attachment → libghostty's
  `.exec` backend → an actual spawned process, end to end, not just
  "compiles." This also resolved `TODO(verify)` #1 above.

Not exercised in this environment: a real `herdr` binary (none installed),
any actual keystroke → pty round trip, the `Ctrl+Shift+1…9` chord against a
real focused surface, and no UI screenshot/manual click-through was taken.
