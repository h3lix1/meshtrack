# Scenario DSL — concrete YAML schema

The acceptance harness (`ScenarioParser` → `ScenarioRunner`) reads scenarios in
this schema. It is inspired by SPEC §6.2; the spec's illustrative `xN` fix-suffix
is replaced by a real `count:` field.

A document is a **YAML list** of node scenarios. An empty document (or comments
only) parses to an empty suite.

```yaml
- node: A123                 # required: node id (!hexid or short id), not the numeric key
  class: fixed               # optional: fixed | mobile | gateway | unknown
  arm:                       # optional: arming config (SPEC §2.3)
    threshold_m: 100         #   required within arm: movement threshold (metres)
    accuracy_margin_m: 0     #   optional (default 0): added to threshold
    confirmation_count: 3    #   optional (default 3): consecutive candidate fixes to confirm
    escape_factor: 3         #   optional (default 3): single-fix immediate-confirm multiple
  fixes:                     # optional: ordered fix steps fed to the detector
    - dlat: 0.0003           #   delta form: degrees offset from anchor …
      dlon: 0.0002
      h_accuracy: 60         #   required on every fix: horizontal accuracy (metres)
      count: 5               #   optional (default 1): repeat this fix N times (replaces `xN`)
    - meters_from_anchor: 600 #  …OR distance form: straight-line metres from anchor
      h_accuracy: 10
      count: 3
  silence_hours: 26          # optional: hours of silence to simulate (SPEC §2.2 stale)
  expect_alerts:             # optional: the exact alerts asserted (by type + count)
    - { type: moved, count: 1 }
```

## Rules
- Each `fixes[]` step picks **exactly one** offset form: `meters_from_anchor` **or**
  `dlat`+`dlon` (both required together). Mixing or omitting both is an error.
- `h_accuracy` is required on every fix so the detector can apply its accuracy
  margin (SPEC §2.3).
- `count` must be ≥ 1; `expect_alerts[].count` must be ≥ 0.
- Unknown `class` values, wrong types, missing required keys, and malformed YAML
  all raise a typed `ScenarioParseError` naming the offending node and key.

## Comparison semantics
The runner compares produced alerts to `expect_alerts` by **type and
multiplicity** (order-insensitive). Detection itself is supplied by an injected
`ScenarioEvaluator`; Phase 0 ships `NoOpEvaluator` (no alerts), so
`expect_alerts: []` scenarios pass and alert-expecting scenarios fail until the
real detectors (MovementDetector / LivenessEvaluator / RuleEngine) are wired in
Phases 2–3.
