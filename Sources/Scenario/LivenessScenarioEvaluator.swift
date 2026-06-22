// LivenessScenarioEvaluator — the real (non-no-op) evaluator for liveness
// scenarios. A scenario's `silence_hours` becomes a stale check through the
// RuleEngine, so the acceptance harness can assert that stale scenarios fire
// exactly the expected alerts (SPEC §6.5 / Phase 2 done-condition).
//
// Ownership (ADR 0008): ownership-sensitive rules (`stale` / `battery_below` /
// `voltage_below`) evaluate ONLY for managed nodes. Management is resolved per
// node through ``RuleEvaluator/conditions(for:rules:now:management:)`` so the gate
// is driven by the node's REAL classification, not a hardcoded "managed" default.
// By default a scenario's own `managed:` flag is authoritative; injecting a
// ``NodeManagementLookup`` (e.g. ``StoreNodeManagementLookup``) lets the live app
// resolve `is_managed` straight from the store.

import Domain
import RuleEngine

public struct LivenessScenarioEvaluator: ScenarioEvaluator {
    private let rules: RuleSet
    private let now: Instant
    /// Resolves each node's ownership classification. When `nil`, the scenario's
    /// own declared `isManaged` flag is used (the harness's self-contained default).
    private let managementLookup: (any NodeManagementLookup)?

    public init(
        rules: RuleSet = RuleSet([AlertRule(type: .stale, scope: .global, threshold: 86400)]),
        now: Instant = Instant(nanosecondsSinceEpoch: 1_000_000_000_000_000),
        managementLookup: (any NodeManagementLookup)? = nil
    ) {
        self.rules = rules
        self.now = now
        self.managementLookup = managementLookup
    }

    public func evaluate(_ scenario: Scenario) -> [ProducedAlert] {
        guard let silenceHours = scenario.silenceHours else { return [] }
        let nodeNum = Self.nodeNum(scenario.node)
        let snapshot = NodeSnapshot(
            nodeNum: nodeNum,
            nodeClass: scenario.nodeClass ?? .unknown,
            lastHeard: now.adding(seconds: -silenceHours * 3600),
            expectedInterval: 3600
        )
        // An injected lookup (production: the live store) wins; otherwise the
        // scenario's own declared ownership drives the gate.
        let management = managementLookup?.management(forNodeNum: nodeNum)
            ?? NodeManagement(isManaged: scenario.isManaged)
        var engine = AlertEngine()
        let conditions = RuleEvaluator.conditions(
            for: snapshot, rules: rules, now: now, management: management
        )
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
