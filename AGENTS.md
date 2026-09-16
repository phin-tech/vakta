# Working on Vakta

## Communication and scope

Give concise, direct answers. Lead with evidence; challenge flawed assumptions.
Skip greetings, praise, and filler. Preserve unrelated working-tree changes.
Review and planning requests authorize investigation and documentation, not fixes.

## Required context

- Before adding or changing behavior, tests, persistence, or build configuration,
  read [the coverage plan](docs/testing.md). Select the relevant regression cases.
- Before editing Swift, read [the Swift engineering rules](docs/swift-practices.md).
- For build/run instructions, read [README.md](README.md) and inspect the current
  package manifest, XcodeGen configuration, and CI workflow.

## TDD: explicit phase gates

For implementation work, follow these phases. Authorization for one phase does
not authorize the next. A general request to fix a feature starts at RED.

1. **RED:** Before writing code, output a brief **Testing Strategy** with separate
   Functional Core (pure input/output) and Imperative Shell (integration/fakes)
   sections. Then write only failing tests for the requested behavior. Run the
   relevant tests when possible and report the expected failure. Halt completely;
   do not write implementation or speculative refactors.
2. **GREEN:** Wait for explicit user approval. Write only the minimal production
   changes needed to pass. Immediately run the relevant suite. If it fails, report
   error logs, fix the implementation, and rerun until the new tests pass. Do not
   ask for another approval within this loop. Once passing, halt completely.
3. **REFACTOR:** Wait for a separate user command. Improve structure without
   changing behavior; run the affected tests and required build checks.

A compilation/toolchain failure is not evidence that a behavioral test is RED.
If the test harness is missing, present the failing test cases and identify the
minimum harness work needed; do not silently add implementation to enable them.
Report external blockers honestly rather than claiming tests passed.
Documentation-only changes use link/content checks; they do not need artificial
unit tests. Behavioral changes discovered while documenting remain separate work.

## Functional core, imperative shell

Keep business decisions in pure functions over value types. Pass time, IDs,
environment snapshots, and external results as inputs; return decisions or next
state. Core code must not read files, spawn processes, mutate shared state, access
AppKit/Ghostty objects, or post notifications.

The shell owns I/O, observable state, task lifetimes, and effect execution. Extract
seams for actual boundaries rather than introducing a protocol for every type.

**Zero mocks by default.** Core tests assert input/output. Shell tests use true
integrations or stateful in-memory fakes and assert observable outcomes. No spies,
mock frameworks, call-count assertions, or private-method interaction tests. If a
mock is unavoidable, explain why real integration and fakes cannot work and wait
for explicit approval before using it.

## Terminal invariants

- One shared terminal controller per process; one surface per live session.
- AppKit owns the permanent terminal host. Selection changes visibility and focus,
  never surface identity. SwiftUI must not conditionally own live terminal views.
- Defer removal triggered by a terminal close callback until outside its teardown
  stack. Preserve idempotency for repeated callbacks.
- Clear Ghostty keybindings when rebuilding configuration. Keep application-menu
  key equivalents empty; route configurable app shortcuts through the matcher.
  Native editor controls still need their normal text-entry behavior.
- Scrub child environments without mutating Vakta's process-wide environment.
- Metal/surface checks require a real desktop session; headless unit tests must
  not launch the application or construct terminal surfaces.

## Discovery and tracking

Prefer codebase-memory MCP for code discovery: `search_graph`, `trace_path`,
`get_code_snippet`, `query_graph`, then `get_architecture` for broad context.
Resolve the indexed project instead of assuming its name. Check that snippets
cover the relevant source and current local changes. Fall back to `rg`/file reads
when graph results are unavailable, stale, truncated, or insufficient; use `rg`
directly for literals and non-code configuration.

Use Kata for durable project work. Read `kata quickstart` and search existing
issues before creating tickets. The cleanup scope is tracked by `vakta#mkwv`.
Use parent links for containment and blocked-by links only for real dependencies.
Close issues only after their acceptance criteria are met with recorded evidence.

## Verification and handoff

Build success is not test success. State which commands ran, which passed, and
which display-dependent checks remain unverified. After harness setup, run focused
regressions and the affected suite; validate both build paths when changes touch
shared sources or target configuration. Keep generated Xcode files generated from
`project.yml`. Do not run install/release recipes as verification: they replace an
installed app or publish tags/artifacts.
