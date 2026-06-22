import Domain
@testable import RuleEngine
import Testing

@Suite("RuleEvaluator + config hierarchy")
struct RuleEvaluatorTests {
    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    /// Ownership-sensitive rules (stale/battery/voltage) only evaluate for managed
    /// nodes (ADR 0008), and `conditions` now requires the flag (no default), so
    /// the rule-mechanics tests below pass a managed node explicitly.
    private let managed = NodeManagement(isManaged: true)

    @Test
    func `effective rule resolves node → class → global precedence`() {
        let rules = RuleSet([
            AlertRule(type: .batteryBelow, scope: .global, threshold: 10),
            AlertRule(type: .batteryBelow, scope: .nodeClass(.fixed), threshold: 20),
            AlertRule(type: .batteryBelow, scope: .node(7), threshold: 30)
        ])
        #expect(rules.effectiveRule(type: .batteryBelow, nodeNum: 7, nodeClass: .fixed)?.threshold == 30)
        #expect(rules.effectiveRule(type: .batteryBelow, nodeNum: 8, nodeClass: .fixed)?.threshold == 20)
        #expect(rules.effectiveRule(type: .batteryBelow, nodeNum: 8, nodeClass: .mobile)?.threshold == 10)
    }

    @Test
    func `a disabled rule is ignored, falling back to the next scope`() {
        let rules = RuleSet([
            AlertRule(type: .batteryBelow, scope: .global, threshold: 10),
            AlertRule(type: .batteryBelow, scope: .node(7), threshold: 30, enabled: false)
        ])
        #expect(rules.effectiveRule(type: .batteryBelow, nodeNum: 7, nodeClass: .fixed)?.threshold == 10)
    }

    @Test
    func `stale fires when silence exceeds the threshold, quiet within it`() {
        let rules = RuleSet([AlertRule(type: .stale, scope: .global, threshold: 3600)])
        let snapshot = NodeSnapshot(nodeNum: 7, nodeClass: .fixed, lastHeard: at(0), expectedInterval: 900)
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(1000), management: managed)
            .isEmpty)
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(4000), management: managed)
            .map(\.type) == [.stale])
    }

    @Test
    func `a stale threshold of 0 falls back to the node's expected interval`() {
        let rules = RuleSet([AlertRule(type: .stale, scope: .global, threshold: 0)])
        let snapshot = NodeSnapshot(nodeNum: 7, nodeClass: .mobile, lastHeard: at(0), expectedInterval: 600)
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(500), management: managed)
            .isEmpty)
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(700), management: managed)
            .map(\.type) == [.stale])
    }

    @Test
    func `battery_below and voltage_below fire under threshold, not above`() {
        let rules = RuleSet([
            AlertRule(type: .batteryBelow, scope: .global, threshold: 20),
            AlertRule(type: .voltageBelow, scope: .global, threshold: 3.3)
        ])
        let low = NodeSnapshot(
            nodeNum: 7, nodeClass: .fixed, lastHeard: at(0),
            expectedInterval: 900, batteryPercent: 15, voltage: 3.1
        )
        #expect(Set(RuleEvaluator.conditions(for: low, rules: rules, now: at(1), management: managed)
                .map(\.type))
            == [.batteryBelow, .voltageBelow])

        let healthy = NodeSnapshot(
            nodeNum: 7, nodeClass: .fixed, lastHeard: at(0),
            expectedInterval: 900, batteryPercent: 80, voltage: 4.0
        )
        #expect(RuleEvaluator.conditions(for: healthy, rules: rules, now: at(1), management: managed).isEmpty)
    }

    @Test
    func `with no rules, nothing fires`() {
        let snapshot = NodeSnapshot(
            nodeNum: 7, nodeClass: .fixed, lastHeard: at(0),
            expectedInterval: 900, batteryPercent: 1, voltage: 1
        )
        #expect(RuleEvaluator.conditions(
            for: snapshot,
            rules: RuleSet([]),
            now: at(99999),
            management: managed
        )
        .isEmpty)
    }

    // MARK: Ownership gating (ADR 0008 / SPEC §2.10)

    private var lowBatterySnapshot: NodeSnapshot {
        NodeSnapshot(
            nodeNum: 7, nodeClass: .fixed, lastHeard: at(0),
            expectedInterval: 900, batteryPercent: 5, voltage: 3.0
        )
    }

    private var ownershipRules: RuleSet {
        RuleSet([
            AlertRule(type: .batteryBelow, scope: .global, threshold: 20),
            AlertRule(type: .voltageBelow, scope: .global, threshold: 3.3),
            AlertRule(type: .stale, scope: .global, threshold: 3600)
        ])
    }

    @Test
    func `an unmanaged node with low battery raises NO alert (no false alarms)`() {
        let conditions = RuleEvaluator.conditions(
            for: lowBatterySnapshot, rules: ownershipRules, now: at(10000),
            management: NodeManagement(isMine: true, isManaged: false)
        )
        #expect(conditions.isEmpty)
    }

    @Test
    func `a managed node with low battery raises exactly one battery alert`() {
        let conditions = RuleEvaluator.conditions(
            for: lowBatterySnapshot, rules: ownershipRules, now: at(1),
            management: NodeManagement(isManaged: true)
        )
        #expect(conditions.count(where: { $0.type == .batteryBelow }) == 1)
    }

    @Test
    func `an explicitly managed node evaluates ownership rules`() {
        // `management:` is now required (no default), so callers must opt in to the
        // managed gate explicitly — a managed node opens it and battery fires.
        let conditions = RuleEvaluator.conditions(
            for: lowBatterySnapshot, rules: ownershipRules, now: at(1), management: managed
        )
        #expect(conditions.contains { $0.type == .batteryBelow })
    }

    @Test
    func `an unmanaged node skips stale and voltage too, not just battery`() {
        let conditions = RuleEvaluator.conditions(
            for: lowBatterySnapshot, rules: ownershipRules, now: at(10000),
            management: .unowned
        )
        #expect(conditions.isEmpty) // stale + voltage + battery all gated off
    }
}
