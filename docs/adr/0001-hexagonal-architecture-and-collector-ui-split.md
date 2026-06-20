# ADR 0001 — Hexagonal architecture & collector/UI split

- Status: accepted
- Date: 2026-06-20

## Context
Meshtrack must alert on liveness, battery, and movement 24/7 — correctly even if
the UI was never opened — and the alerting logic (movement confirmation, staleness,
storm suppression) must be deterministically testable in CI without hardware, a
broker, or a wall clock.

## Decision
Adopt hexagonal (ports-and-adapters) architecture with a hard split:

- **`Domain` is pure**: no Foundation I/O, no `Date()`, no network, no DB. All
  effects enter through ports (`Clock`, `MeshTransport`, `Store`, `Notifier`,
  `Flasher`, `KeyStore`). Domain imports only the standard library.
- **`meshtrackd`** is a headless `launchd` LaunchAgent that runs the ingestion and
  alerting pipeline always-on; the **SwiftUI app** is a viewer/controller over a
  shared GRDB store (WAL) and/or XPC.
- Ingestion and per-node mutable state live in **actors**; everything crossing a
  boundary is `Sendable`.

## Consequences
- The fitness function (`make verify`) is deterministic: the same scenario always
  yields the same alert sequence, enabling snapshot acceptance tests and mutation
  testing.
- Liveness/battery alerts do not depend on the app being open.
- Slightly more boilerplate (ports + fakes) — accepted as the cost of testability
  and the precondition for a convergent autonomous build loop.
- Single-Mac deployment (SPEC §10): the shared store is local; XPC bridges the
  collector and app on one machine. No multi-machine store.
