# ADR 0004 — Movement detection: confirmation + accuracy margin + hysteresis

- Status: accepted
- Date: 2026-06-20

## Context
Naively subtracting positions yields constant false "moved" alerts from GPS
jitter. The detector must produce **zero** false positives on jitter inside the
accuracy envelope and confirm a real move exactly once, without flapping (SPEC §2.3).

## Decision
`MovementDetector` is a pure, stateful value type:
- A fix is a **candidate** only when its Haversine distance from the anchor exceeds
  `threshold + accuracyMargin + fixAccuracy + anchorAccuracy` — the boundary widens
  with reported accuracy, so jitter never qualifies.
- Movement is **confirmed** by `N` consecutive candidates (default 3) OR a single
  fix beyond the boundary by `escapeFactor` (default 3×).
- **Hysteresis:** once moved, it returns only after sustained re-entry inside
  `threshold * returnRatio` (default 0.6) for `N` fixes — no flapping.
- Fixes coarser than the threshold are ignored; no-GPS nodes are never fed in.
- Class semantics: `mobile` nodes emit `geofence_exit` rather than `moved`.

Trig uses the platform math library (`Darwin`) — pure functions only, so Domain
stays Foundation-free and deterministic.

## Consequences
- Acceptance harness proves jitter→0 alerts, a 600m move→exactly one, mobile→
  geofence_exit. The detector is the spec's signature feature and is fully
  property-style tested.
