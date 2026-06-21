// LivenessScenarioEvaluator — the real (non-no-op) evaluator for liveness
// scenarios. A scenario's `silence_hours` becomes a stale check through the
// RuleEngine, so the acceptance harness can assert that stale scenarios fire
// exactly the expected alerts (SPEC §6.5 / Phase 2 done-condition).

import Domain
import RuleEngine

public struct LivenessScenarioEvaluator: ScenarioEvaluator {
    private let rules: RuleSet
    private let now: Instant

    public init(
        rules: RuleSet = RuleSet([AlertRule(type: .stale, scope: .global, threshold: 86400)]),
        now: Instant = Instant(nanosecondsSinceEpoch: 1_000_000_000_000_000)
    ) {
        self.rules = rules
        self.now = now
    }

    public func evaluate(_ scenario: Scenario) -> [ProducedAlert] {
        guard let silenceHours = scenario.silenceHours else { return [] }
        let snapshot = NodeSnapshot(
            nodeNum: Self.nodeNum(scenario.node),
            nodeClass: scenario.nodeClass ?? .unknown,
            lastHeard: now.adding(seconds: -silenceHours * 3600),
            expectedInterval: 3600
        )
        var engine = AlertEngine()
        let conditions = RuleEvaluator.conditions(for: snapshot, rules: rules, now: now)
        return engine.reconcile(conditions, now: now).compactMap { event in
            if case let .fired(alert) = event {
                ProducedAlert(type: alert.type.rawValue, firedAt: alert.firedAt)
            } else {
                nil
            }
        }
    }

    /// Parse a `!hexid`, else a stable hash — the value is irrelevant to liveness.
    private static func nodeNum(_ id: String) -> UInt32 {
        var trimmed = Substring(id)
        if trimmed.first == "!" { trimmed = trimmed.dropFirst() }
        return UInt32(trimmed, radix: 16) ?? UInt32(truncatingIfNeeded: id.hashValue)
    }
}
