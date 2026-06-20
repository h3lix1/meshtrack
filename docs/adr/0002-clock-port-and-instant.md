# ADR 0002 — Clock port and the `Instant` time type

- Status: accepted
- Date: 2026-06-20

## Context
Staleness, movement confirmation windows, cooldown/snooze, and dedup windows are
all time-dependent. If Domain reads the wall clock (`Date()`), tests become
non-deterministic and the replay pipeline cannot drive time from packet `rx_time`.

## Decision
- Introduce a `Clock` port in Domain: `func now() -> Instant`.
- Time is a Domain-native `Instant` = integer nanoseconds since the Unix epoch.
  Using `Int64` nanoseconds (not Foundation `Date`) keeps Domain free of Foundation
  and makes instants exactly persistable and comparable.
- `InjectedClock` (pure, in Domain) advances deterministically. It is used by unit
  tests *and* by the production replay pipeline (time = packet `rx_time`).
- `SystemClock` (the only `Date()`-backed clock) lives in the `meshtrackd`
  composition root, never in Domain.
- `Date()` is **banned in Domain**, enforced by `scripts/check-domain-purity.sh`
  (always runs) and a SwiftLint custom rule (`domain_no_date`).

## Consequences
- Every time-dependent detector is deterministic and unit-testable.
- Replay can compress/skip time precisely.
- Adapters must convert host time to `Instant` at the boundary (a one-line
  `timeIntervalSince1970 → nanoseconds` conversion in `SystemClock`).
