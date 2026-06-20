// The evaluation seam between the acceptance harness and the real detectors.
//
// The runner does NOT know how alerts are produced — that is the job of the
// MovementDetector / LivenessEvaluator / RuleEngine, which land in Phases 2–3.
// To keep the harness shippable in Phase 0 and stable thereafter, the runner
// drives a `ScenarioEvaluator` port. Later phases provide a real evaluator that
// replays the scenario's fixes/silence through those detectors; today we ship a
// no-op evaluator so empty-expectation scenarios pass and the comparison logic is
// exercised end-to-end.

import Domain

/// One alert produced while evaluating a scenario.
///
/// The harness compares produced alerts to ``ExpectedAlert`` by *type and
/// multiplicity*. `firedAt` is retained for richer future assertions (ordering,
/// cooldown windows) and to give the eventual real evaluator a place to record
/// when, on the injected clock, each alert fired.
public struct ProducedAlert: Sendable, Equatable {
    public var type: String
    public var firedAt: Instant?

    public init(type: String, firedAt: Instant? = nil) {
        self.type = type
        self.firedAt = firedAt
    }
}

/// Port: turns a parsed ``Scenario`` into the alerts it produces.
///
/// Implementations are the integration point for the real detection pipeline.
/// They must be deterministic (drive time from the injected clock, never the wall
/// clock) so the acceptance suite stays reproducible.
public protocol ScenarioEvaluator: Sendable {
    /// Evaluate one node scenario and return every alert it produced, in fired
    /// order.
    func evaluate(_ scenario: Scenario) -> [ProducedAlert]
}

/// The Phase 0 default evaluator: produces no alerts for any scenario.
///
/// This makes `expect_alerts: []` scenarios PASS today, and makes any scenario
/// that expects an alert FAIL — which is exactly what we want until the real
/// detectors are wired, and is what proves the runner's comparison works.
public struct NoOpEvaluator: ScenarioEvaluator {
    public init() {}

    public func evaluate(_: Scenario) -> [ProducedAlert] {
        []
    }
}
