import Domain
@testable import RuleEngine
import Testing

@Suite("RuleEvaluator + config hierarchy")
struct RuleEvaluatorTests {
    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

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
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(1000)).isEmpty)
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(4000)).map(\.type) == [.stale])
    }

    @Test
    func `a stale threshold of 0 falls back to the node's expected interval`() {
        let rules = RuleSet([AlertRule(type: .stale, scope: .global, threshold: 0)])
        let snapshot = NodeSnapshot(nodeNum: 7, nodeClass: .mobile, lastHeard: at(0), expectedInterval: 600)
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(500)).isEmpty)
        #expect(RuleEvaluator.conditions(for: snapshot, rules: rules, now: at(700)).map(\.type) == [.stale])
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
        #expect(Set(RuleEvaluator.conditions(for: low, rules: rules, now: at(1)).map(\.type))
            == [.batteryBelow, .voltageBelow])

        let healthy = NodeSnapshot(
            nodeNum: 7, nodeClass: .fixed, lastHeard: at(0),
            expectedInterval: 900, batteryPercent: 80, voltage: 4.0
        )
        #expect(RuleEvaluator.conditions(for: healthy, rules: rules, now: at(1)).isEmpty)
    }

    @Test
    func `with no rules, nothing fires`() {
        let snapshot = NodeSnapshot(
            nodeNum: 7, nodeClass: .fixed, lastHeard: at(0),
            expectedInterval: 900, batteryPercent: 1, voltage: 1
        )
        #expect(RuleEvaluator.conditions(for: snapshot, rules: RuleSet([]), now: at(99999)).isEmpty)
    }
}
