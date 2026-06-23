// RuleEvaluator — pure liveness/battery/voltage evaluation (SPEC §2.2/§2.6).
//
// Given a node's observed snapshot, the effective rules, and `now` (from the
// Clock port), produce the alert conditions that currently hold. Deterministic
// and side-effect-free; the AlertEngine state machine wraps this.

import Domain

/// A node's observed state at evaluation time.
public struct NodeSnapshot: Sendable, Equatable {
    public let nodeNum: UInt32
    public let nodeClass: NodeClass
    public let lastHeard: Instant
    /// Expected heard interval (seconds); the `stale` fallback when a rule's
    /// threshold is 0.
    public let expectedInterval: Double
    public let batteryPercent: Double?
    public let voltage: Double?

    public init(
        nodeNum: UInt32,
        nodeClass: NodeClass,
        lastHeard: Instant,
        expectedInterval: Double,
        batteryPercent: Double? = nil,
        voltage: Double? = nil
    ) {
        self.nodeNum = nodeNum
        self.nodeClass = nodeClass
        self.lastHeard = lastHeard
        self.expectedInterval = expectedInterval
        self.batteryPercent = batteryPercent
        self.voltage = voltage
    }
}

/// A condition that currently holds for a node (pre-state-machine). Carries the
/// effective rule's cooldown so the engine can rate-limit re-firing.
public struct AlertCondition: Sendable, Equatable {
    public let type: AlertType
    public let nodeNum: UInt32
    public let detail: String
    public let cooldownSeconds: Double

    public init(type: AlertType, nodeNum: UInt32, detail: String, cooldownSeconds: Double = 0) {
        self.type = type
        self.nodeNum = nodeNum
        self.detail = detail
        self.cooldownSeconds = cooldownSeconds
    }
}

public enum RuleEvaluator {
    /// The liveness + battery/voltage conditions that hold for `snapshot` now.
    ///
    /// - Parameter management: the node's ownership classification (SPEC §2.10,
    ///   ADR 0008). **Ownership-sensitive rules — `stale`, `battery_below`,
    ///   `voltage_below` — evaluate only when the node is managed**, so we never
    ///   raise battery/silence alerts for strangers' nodes. The node → class →
    ///   global config hierarchy is unchanged: this gate is applied *after*
    ///   resolution, never altering it. **Required, with no default**: omitting a
    ///   node's ownership must be a compile error, never a silent "treat as
    ///   managed" that fires stale/battery alerts for unclassified strangers
    ///   (ADR 0008 — Domain defaults a fresh node to ``NodeManagement/unowned``).
    public static func conditions(
        for snapshot: NodeSnapshot,
        rules: RuleSet,
        now: Instant,
        management: NodeManagement
    ) -> [AlertCondition] {
        var conditions: [AlertCondition] = []
        // Ownership-sensitive rules: skipped entirely for unmanaged nodes.
        if management.evaluatesOwnershipRules {
            if let condition = staleCondition(snapshot, rules: rules, now: now) {
                conditions.append(condition)
            }
            if let condition = batteryCondition(snapshot, rules: rules) { conditions.append(condition) }
            if let condition = voltageCondition(snapshot, rules: rules) { conditions.append(condition) }
        }
        return conditions
    }

    private static func staleCondition(
        _ snapshot: NodeSnapshot,
        rules: RuleSet,
        now: Instant
    ) -> AlertCondition? {
        guard let rule = rules.effectiveRule(
            type: .stale,
            nodeNum: snapshot.nodeNum,
            nodeClass: snapshot.nodeClass
        )
        else { return nil }
        let silence = now.secondsSince(snapshot.lastHeard)
        let threshold = rule.threshold > 0 ? rule.threshold : snapshot.expectedInterval
        guard silence > threshold else { return nil }
        return AlertCondition(
            type: .stale,
            nodeNum: snapshot.nodeNum,
            detail: "silent for \(Int(silence))s (> \(Int(threshold))s)",
            cooldownSeconds: rule.cooldownSeconds
        )
    }

    private static func batteryCondition(_ snapshot: NodeSnapshot, rules: RuleSet) -> AlertCondition? {
        guard let rule = rules.effectiveRule(
            type: .batteryBelow,
            nodeNum: snapshot.nodeNum,
            nodeClass: snapshot.nodeClass
        ),
            let battery = snapshot.batteryPercent, battery < rule.threshold else { return nil }
        return AlertCondition(
            type: .batteryBelow,
            nodeNum: snapshot.nodeNum,
            detail: "battery \(battery)% < \(rule.threshold)%",
            cooldownSeconds: rule.cooldownSeconds
        )
    }

    private static func voltageCondition(_ snapshot: NodeSnapshot, rules: RuleSet) -> AlertCondition? {
        guard let rule = rules.effectiveRule(
            type: .voltageBelow,
            nodeNum: snapshot.nodeNum,
            nodeClass: snapshot.nodeClass
        ),
            let voltage = snapshot.voltage, voltage < rule.threshold else { return nil }
        return AlertCondition(
            type: .voltageBelow,
            nodeNum: snapshot.nodeNum,
            detail: "voltage \(voltage)V < \(rule.threshold)V",
            cooldownSeconds: rule.cooldownSeconds
        )
    }
}
