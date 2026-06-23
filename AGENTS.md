# AGENTS.md — engineering guardrails

This file constrains *how* Meshtrack is built. `SPEC.md` defines *what*.
`make verify` is the single validator that must be green before any commit.

## Architecture
- `Domain` imports nothing but the standard library (+ `Synchronization`) and other
  Domain types. No Foundation I/O, no `Date()`, no network, no GRDB. All effects via
  ports. Enforced by `scripts/check-domain-purity.sh` (always runs) and a SwiftLint
  custom rule.
- The module dependency graph is acyclic (SwiftPM enforces) and matches `SPEC §3`.
- Ports live at the Domain boundary; adapters live in the outer ring. Every new
  effect ships with a fake adapter.

## Concurrency
- Swift 6 strict concurrency, **zero warnings** (warnings-as-errors per target).
  Mutable state lives in actors. Everything crossing a boundary is `Sendable`.
- Use Use multiple parallel background tasks whenever possible to get done work faster.

## Safety
- No force-unwraps / `try!` / `as!` in non-test code. Typed errors. Any
  `swiftlint:disable` needs an inline justification.
- Runtime config (broker password, channel PSKs) lives in the app's local SQLite
  store, not the repo; redact secrets in logs (enforced by a logging wrapper).

## Process
- Trunk-based; conventional commits; one focused change per commit.
- **No commit unless `make verify` is green.** Never skip/delete tests, lower the
  coverage floor, widen a movement threshold to mask a bug, or put effects in Domain.
- Every behavioral change ships with a test; every new effect ships with a fake.
- Public API documented (DocC).

## Definition of done (per task)
1. Code + tests + docs. 2. `make verify` green. 3. Relevant acceptance snapshot passes.

## Anti-patterns to reject
Mocking the system under test; deleting/`xfail`-ing tests; lowering the coverage
floor; putting effects in Domain; widening movement thresholds to silence a flaky
test instead of fixing the detector; auto-flashing firmware.

---

## Worktree-agent rules (parallel build)
When several agents build in parallel git worktrees, collisions are avoided by
freezing shared files:
- **Do NOT edit `Package.swift`.** It already declares every target and dependency.
  If you genuinely need a new dependency, STOP and flag it for the lead — do not add
  it yourself.
- Stay within your module's `Sources/<Module>/` and `Tests/<Module>Tests/`. Touch
  `scripts/` only for a gate your task owns (e.g. Agent D owns `scripts/gen-protos.sh`).
- Keep `Domain` pure. Add fakes for new effects.
- Before declaring done: `swift build && swift test` green, plus your task's gate
  (e.g. `scripts/check-protobuf-codegen.sh` for codegen). The lead runs the full
  `make verify` after integrating worktrees.

---

## Resolved project decisions (SPEC §10)
- **Broker:** public `mqtt.meshtastic.org`; honor zero-hop uplink policy.
- **Channels/PSKs:** in-app config, MQTT uncapped / 7 local (firmware limit); stored in the local SQLite app store.
- **Remote admin:** support BOTH PKI admin key and legacy admin channel.
- **Deployment:** single-Mac; shared GRDB store (WAL) + XPC; no multi-machine.
- **macOS floor:** 26.6 (latest).

## Toolchain notes
- `swiftformat`, `swiftlint`: `brew install` (see `make bootstrap`).
- `protoc` + `protoc-gen-swift`: for `MeshProtos` codegen (Agent D).
- **CI** (`.github/workflows/verify.yml`) runs on `macos-latest` and selects the
  newest Xcode. Meshtrack needs Xcode 26 / Swift 6.2; until GitHub images ship it,
  CI may require a self-hosted runner.
- `make verify` degrades gracefully for absent local tools (warns + skips); CI
  installs everything and enforces every gate with no skips.

## Imported Claude Cowork project instructions
