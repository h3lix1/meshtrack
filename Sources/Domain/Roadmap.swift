// Domain roadmap — pure components that land in later phases.
//
// Each of these is a PURE type (no Foundation, no Date(), no I/O) that takes its
// inputs as values and its time from the `Clock` port. They are listed here so
// the intended shape of the Domain is visible from commit #1; the real types are
// authored in the phase noted.
//
//   • MovementDetector   (Phase 3, SPEC §2.3) — anchor + confirmation + accuracy
//                         margin + hysteresis; jitter inside h_accuracy never
//                         confirms movement.
//   • LivenessEvaluator  (Phase 2, SPEC §2.2) — heard/stale from last_heard_at
//                         and per-node expected_interval.
//   • RuleEngine core    (Phase 2, SPEC §2.6) — typed rules + config hierarchy
//                         (node → class → global) + alert state machine.
//   • TemplateRenderer   (Phase 4, SPEC §2.7/§2.1) — naming DSL with hard byte
//                         limits (short ≤ 4 bytes, long ≤ 39 bytes).
//
// See SPEC.md for the behavioral contract.
