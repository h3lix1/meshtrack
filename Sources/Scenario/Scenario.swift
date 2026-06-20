// Scenario — the acceptance harness: a YAML scenario DSL parser
// (``ScenarioParser``) + a runner (``ScenarioRunner``) that drives the detection
// pipeline through a pluggable ``ScenarioEvaluator`` and asserts an exact alert
// sequence against `expect_alerts` (SPEC §6.2/§6.5).
//
// The typed model lives in `ScenarioModel.swift`; the concrete YAML schema is
// documented in `SCHEMA.md`. The real detectors (MovementDetector /
// LivenessEvaluator / RuleEngine) wire in via `ScenarioEvaluator` in Phases 2–3
// without changing this harness; Phase 0 ships ``NoOpEvaluator``.

/// Module marker. Retained as a cheap linkability check; the module's real
/// surface is ``ScenarioParser``, ``ScenarioRunner``, and ``Scenario``.
public enum ScenarioModule {
    public static let name = "Scenario"
}
