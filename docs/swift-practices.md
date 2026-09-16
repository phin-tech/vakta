# Swift engineering rules

Read this before changing Swift in Vakta. These are target conventions for touched
code; existing violations are not permission for an unrelated rewrite.

## Compatibility and API design

Inspect `Package.swift`, `project.yml`, and the selected compiler before adopting
new language or SDK features. The current manifest declares Swift tools 5.10 and
macOS 13; that is not a declaration of Swift 6 language mode. Preserve the minimum
deployment target and both SwiftPM and Xcode builds unless a migration is requested.

Use descriptive domain names and argument labels that make call sites clear.
Prefer small value types, `let`, enums for mutually exclusive states, and explicit
results for recoverable outcomes. Give reference types identity/ownership reasons;
mark classes `final` when subclassing is not required. Keep access as narrow as the
module permits. Document invariants and surprising constraints rather than narrating
each line. These naming conventions follow the
[Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).

## Pure domain types and adapters

Profile validation, launch specifications, keybinding migrations, target identity,
agent aggregation, notification decisions, restoration plans, and selection rules
belong in pure value-based code. Keep AppKit colors, event objects, terminal surface
options, and OS notification payloads in adapters. Decode/validate external data at
the boundary before it enters the core. Supply UUIDs, time, shell/environment values,
and theme catalog results rather than retrieving them inside decision functions.

Use closures or small protocols where an I/O dependency actually needs replacement.
Do not create generic repositories, service locators, or one-protocol-per-class
layers without a concrete boundary to isolate.

## Concurrency and ownership

- Isolate AppKit/SwiftUI state and terminal UI operations to `@MainActor`.
- Run blocking process waits and file operations outside the UI actor. Creating
  `Task {}` inside actor-isolated code does not by itself move blocking work off
  that actor. Choose an explicit boundary compatible with the supported compiler.
- Pass immutable, `Sendable` snapshots across isolation boundaries rather than
  capturing mutable stores or terminal views in background work.
- Give every long-lived task, timer, subscription, and event monitor an owner and
  a stop path. Bound concurrency, propagate cancellation, and reject obsolete
  results after suspension or profile/session changes.
- Actor isolation prevents concurrent access, but does not make a result current:
  validate generation and identity before applying asynchronous completions.
- Use weak captures when an owned closure would otherwise retain its owner.
  Strong captures are valid when their lifetime is intentional and bounded.
- Resolve isolation warnings through ownership and boundaries. `@unchecked
  Sendable`, `nonisolated(unsafe)`, and `assumeIsolated` need a documented, verifiable
  invariant, not merely a desire to silence diagnostics.

Consult the language's [concurrency guide](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
and [Sendable reference](https://docs.swift.org/latest/documentation/swift/sendable/)
when changing isolation boundaries.

## Observable state and UI

Keep SwiftUI bodies as projections of state; put process/file work and business
decisions elsewhere. Store durable state with the model owner and transient editing
state with the editor. Observe nested objects explicitly where their changes drive
rendering. Avoid mirrored mutable selection or settings state without a defined owner.

In Combine sinks, use the emitted `@Published` value instead of synchronously
rereading the property being published. Apply logically atomic edits as one state
update, so persistence and subscribers do not see intermediate invalid values.
Use stable IDs for session/profile identity, not titles or array positions.

Preserve normal field editing, accessibility labels/actions, keyboard navigation,
and input-method composition. Shortcut routing must know whether a terminal, editor,
recording control, or switcher owns input. State-dependent behavior needs tests;
visual appearance also needs a desktop check.

## Persistence, processes, and errors

Distinguish absent, corrupt, unsupported-version, and unreadable data. Defaults are
an explicit recovery policy, not a reason to overwrite a failed decode. Use atomic
writes, preserve originals during migrations/recovery, and report save failures.
Inject storage roots; tests must never use real user Application Support files.
Validate numeric ranges and finite values before narrowing conversions or UI use.
Use explicit decoding defaults/migrations when adding persisted fields; property
initializer defaults alone do not define backward-compatible decoding.

Prefer executable plus argv for subprocess helpers. Where terminal commands require
shell text, define the quoting/placeholder contract and treat substituted names as
data. Preserve the intended executable, endpoint, environment, and working directory.
Drain pipes while children run, bound execution/output, and handle cancellation and
reaping. Capture useful diagnostics without recording environment secrets.

Use `throws` or typed results for actionable failures. Reserve `try?` for an explicitly
acceptable loss of error information. Avoid force unwraps/casts on external data;
reserve preconditions for internal invariants that the program establishes.

## Test implementation conventions

Follow [AGENTS.md](../AGENTS.md) for phase gates and [testing.md](testing.md) for cases.
Prefer XCTest for initial infrastructure compatible with the current declared tools
baseline. Swift Testing is an option only after confirming the supported toolchain;
Xcode 16 introduced its project testing-system support. Do not require a toolchain
upgrade as incidental cleanup. See Apple's
[test-target guidance](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project).

Name tests by behavior and condition. Assert values, externally visible state, and
preserved data. Parameterize meaningful edge cases; avoid snapshots of arbitrary
implementation details. Use temporary directories, real helper processes, and
controllable clocks/results instead of sleeping or testing callback counts.
