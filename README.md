<p align="center">
  <img src="docs/logo.png" alt="Vakta" width="220">
</p>

# Vakta

Vakta is a native macOS terminal designed with one specific job: managing
**herdr** (and tmux) multiplexer sessions alongside a visual sidebar. It handles
terminal rendering via **libghostty** (using the prebuilt Swift package
[`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm)).

> **Status:** Early but functional — a real macOS `.app` with tagged
> [DMG releases](https://github.com/phin-tech/vakta/releases). Release DMGs
> are ad-hoc (Gatekeeper-quarantined when downloaded) unless the repo's
> signing secrets are configured — see [Releasing](#releasing) to
> de-quarantine an ad-hoc build, or to enable signing.

<p align="center">
  <img src="docs/screenshot.png" alt="Vakta managing herdr sessions" width="900">
</p>

## Core Features

- **Visual Session Switching** — Seamlessly switch between multiplexer sessions
  using the native sidebar or keyboard shortcuts (`Ctrl+Shift+1…9`, rebindable).
- **Session Profiles** — Launch sessions from data-driven profiles, with
  built-in defaults for herdr, tmux, and a standard login shell. Profiles carry
  free-form arguments (with `{name}` substituted for the session), so remote
  sessions are just `--remote me@host --session {name}`. Edit them in a modal.
- **Smart Environment Scrubbing** — Vakta prevents recursive multiplexer nesting
  by scrubbing `HERDR_*` / `TMUX` variables from the spawned child (via an
  `env -u …` prefix), so it never has to mutate its own environment.
- **Continuous Persistence** — Reattaches to still-running server sessions on
  launch rather than restoring dead terminal views. Profiles and workspace state
  are saved in `~/Library/Application Support/Vakta/`.
- **Stable Rendering** — Terminal views are hosted in a plain AppKit `NSView`
  rather than a SwiftUI container, so SwiftUI state diffs can't accidentally tear
  down and kill live terminal surfaces.

## Architecture

- **Terminal Core** — Pinned to `libghostty-spm` (tag `1.6.20260909`, see
  "Pinned dependency" below). We use the prebuilt XCFramework binary rather
  than building Zig from source.
- **Process Model** — One shared `TerminalController` per app process, handed to
  individual `Session` instances that manage their own terminal surfaces.
- **PTY Ownership** — libghostty completely owns the PTY and child-process
  spawning (using backend `.exec`).
- **Input Routing** — Session-switching shortcuts bypass the terminal via a local
  `NSEvent` monitor (`.keyDown` and `.flagsChanged`, the latter for the
  passthrough double-tap). All other keystrokes fall through directly to
  libghostty for flawless terminal passthrough (`keybind = clear`).

See [docs/architecture.md](docs/architecture.md) for the full rationale behind
these invariants (why the terminal host is a permanent AppKit subview, why
shortcuts route through one matcher instead of menu key equivalents, ...) and
[AGENTS.md](AGENTS.md) for the functional-core/imperative-shell pattern the
Swift code follows.

### Pinned dependency

libghostty-spm's embedding C API is unstable upstream, so it's pinned to an
**exact** tag (`1.6.20260909`) rather than a range or branch, in **two**
places that must stay in sync:

- `Package.swift` — `.package(url: "...", exact: "...")`
- `project.yml` — `packages.libghostty-spm.exactVersion`

To bump it: update both, run `xcodegen generate`, then `swift build` and the
Xcode build path (below) to confirm the new tag still exposes the same
`GhosttyKit`/`GhosttyTerminal`/`GhosttyTheme` products Vakta depends on.
`swift package resolve` (or a fresh `swift build`) re-pins `Package.resolved`;
commit that alongside the manifest changes.

## Building and Running

Requires macOS 13 or later on Apple Silicon — `libghostty-spm` ships an
arm64-only xcframework, so there is no Intel build.

Because libghostty renders with Metal, Vakta must run in a real macOS UI
session. It will crash if launched completely headlessly (e.g. over SSH with no
console user), because the Metal rendering context requires a display.

### Quick start (SPM)

For quick iteration, build and run via Swift Package Manager:

```sh
swift build
swift run Vakta
```

Or with [`just`](https://github.com/casey/just): `just run` (app), `just app`
(build + open the `.app`), `just dmg` (local DMG), `just release 0.1.4` (tag +
push). Run `just` to list all recipes.

If you don't have herdr installed locally and just want to test the UI, force a
standard shell:

```sh
VAKTA_TERMINAL_COMMAND=/bin/zsh swift run Vakta
```

### Building the .app bundle

Vakta uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to manage the Xcode
project file.

```sh
# Generate the project file (only when project.yml changes)
brew install xcodegen
xcodegen generate

# Build the app
xcodebuild -project Vakta.xcodeproj -scheme Vakta -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode build

# Run it
open .build/xcode/Build/Products/Debug/Vakta.app
```

Local builds are signed ad-hoc. The app is **not sandboxed**, since it needs to
spawn arbitrary child processes.

## Releasing

Cutting a release is just pushing a version tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

GitHub Actions (`.github/workflows/release.yml`, Apple-Silicon runner) then
builds Release, packages a `.dmg`, and attaches it to an auto-created GitHub
Release. `.github/workflows/ci.yml` builds every push/PR to `main`.

By default the DMG is **ad-hoc and unsigned** — it runs locally but is
Gatekeeper-quarantined when downloaded. After dragging `Vakta.app` to
Applications, clear the quarantine flag to open it:

```sh
xattr -dr com.apple.quarantine /Applications/Vakta.app
```

(or right-click → Open the first time). For signed + notarized DMGs that skip
this entirely, add these repo secrets (Settings → Secrets → Actions):
`MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PWD`, `MACOS_SIGN_IDENTITY`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. All six must be set
together — the release job fails fast (before building) on a partial set
rather than attempting a signed build with one missing.

## Contributing

Read [AGENTS.md](AGENTS.md) for the required TDD approval gates and architecture
rules. [CLAUDE.md](CLAUDE.md) points Claude to the same instructions.
[docs/architecture.md](docs/architecture.md) is the durable reference for
cross-cutting invariants; the [test coverage plan](docs/testing.md) maps core,
integration, and desktop checks (including its "Desktop regression checklist"
for display-backed terminal/keyboard/notification behavior automated tests
can't reach); the [Swift engineering rules](docs/swift-practices.md) cover
concurrency, persistence, input handling, and compatibility.

Running the automated suites:

```sh
swift test                         # VaktaCoreTests + VaktaIntegrationTests
for t in Tests/scripts/test_*.sh   # release version/signing/install scripts
do bash "$t"; done
```

Both run in CI (`.github/workflows/ci.yml`) alongside `swift build` and the
generated Xcode app build. Neither substitutes for the desktop checklist in
[docs/testing.md](docs/testing.md) -- Metal-backed terminal surfaces, real
notification delivery, and IME composition all need a logged-in desktop
session.

## License

MIT — see [LICENSE](LICENSE). Vakta embeds
[`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) (MIT), which wraps
Ghostty's terminal core.
