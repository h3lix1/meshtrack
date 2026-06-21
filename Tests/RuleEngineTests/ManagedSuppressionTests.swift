// ManagedSuppressionTests — the ADR 0008 acceptance proof for G5.
//
// The contract: ownership-sensitive rules (battery_below / voltage_below / stale)
// evaluate ONLY for managed nodes, so we never raise false battery/silence alerts
// for strangers' nodes. RuleEvaluatorTests already covers the evaluator gate in
// isolation; this file proves the same gate end-to-end *through the full pipeline*
// the live collector uses — RuleEvaluator → AlertEngine — so the suppression is a
// real "no fired event", not just an empty condition list.

import Domain
@testable import RuleEngine
import Testing

@Suite("Managed-aware suppression proof (ADR 0008, end-to-end)")
struct ManagedSuppressionTests {
    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    /// A low-battery / low-voltage / silent node — every ownership rule would fire
    /// if the node were managed.
    private var lowNode: NodeSnapshot {
        NodeSnapshot(
            nodeNum: 0xA1B2_C3D4, nodeClass: .fixed, lastHeard: at(0),
            expectedInterval: 900, batteryPercent: 5, voltage: 3.0
        )
    }

    private var rules: RuleSet {
        RuleSet([
            AlertRule(type: .batteryBelow, scope: .global, threshold: 20),
            AlertRule(type: .voltageBelow, scope: .global, threshold: 3.3),
            AlertRule(type: .stale, scope: .global, threshold: 3600)
        ])
    }

    /// Run the live pipeline once: evaluate conditions for `management`, then
    /// reconcile them through the AlertEngine, returning the delivered events.
    private func pipeline(_ management: NodeManagement, now: Instant) -> [AlertEvent] {
        let conditions = RuleEvaluator.conditions(
            for: lowNode, rules: rules, now: now, management: management
        )
        var engine = AlertEngine()
        return engine.reconcile(conditions, now: now)
    }

    @Test
    func `unmanaged low-battery node fires NO alert through the pipeline`() {
        let events = pipeline(NodeManagement(isMine: true, isManaged: false), now: at(10000))
        #expect(events.isEmpty)
    }

    @Test
    func `a stranger node (neither mine nor managed) is fully silent`() {
        let events = pipeline(.unowned, now: at(10000))
        #expect(events.isEmpty)
    }

    @Test
    func `managed low-battery node fires exactly one battery alert`() {
        let events = pipeline(NodeManagement(isManaged: true), now: at(1))
        let batteryFired = events.compactMap { event -> Alert? in
            if case let .fired(alert) = event, alert.type == .batteryBelow { return alert }
            return nil
        }
        #expect(batteryFired.count == 1)
        #expect(batteryFired.first?.nodeNum == 0xA1B2_C3D4)
    }

    @Test
    func `flipping a node from unmanaged to managed starts surfacing its alerts`() {
        // Same node, same conditions, only the management flag changes.
        let now = at(10000)
        #expect(pipeline(.unowned, now: now).isEmpty)
        let managed = pipeline(NodeManagement(isMine: true, isManaged: true), now: now)
        #expect(managed.contains { event in
            if case let .fired(alert) = event { return alert.type == .batteryBelow }
            return false
        })
    }
}
