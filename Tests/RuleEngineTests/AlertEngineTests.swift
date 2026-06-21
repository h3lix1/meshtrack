import Domain
@testable import RuleEngine
import Testing

@Suite("AlertEngine state machine")
struct AlertEngineTests {
    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    private func stale(_ node: UInt32, cooldown: Double = 0) -> AlertCondition {
        AlertCondition(type: .stale, nodeNum: node, detail: "stale", cooldownSeconds: cooldown)
    }

    private func firedNodes(_ events: [AlertEvent]) -> [UInt32] {
        events.compactMap { event -> UInt32? in
            if case let .fired(alert) = event { alert.nodeNum } else { nil }
        }
    }

    private func resolvedNodes(_ events: [AlertEvent]) -> [UInt32] {
        events.compactMap { event -> UInt32? in
            if case let .resolved(alert) = event { alert.nodeNum } else { nil }
        }
    }

    @Test
    func `a new condition fires once; a persisting one does not re-fire`() {
        var engine = AlertEngine()
        #expect(firedNodes(engine.reconcile([stale(7)], now: at(0))) == [7])
        #expect(engine.reconcile([stale(7)], now: at(10)).isEmpty)
        #expect(engine.alert(type: .stale, nodeNum: 7)?.state == .firing)
    }

    @Test
    func `a condition that clears resolves`() {
        var engine = AlertEngine()
        _ = engine.reconcile([stale(7)], now: at(0))
        #expect(resolvedNodes(engine.reconcile([], now: at(10))) == [7])
        #expect(engine.alert(type: .stale, nodeNum: 7)?.state == .resolved)
    }

    @Test
    func `cooldown prevents immediate re-firing after resolve`() {
        var engine = AlertEngine()
        _ = engine.reconcile([stale(7, cooldown: 100)], now: at(0))
        _ = engine.reconcile([], now: at(10)) // resolved at 10
        #expect(engine.reconcile([stale(7, cooldown: 100)], now: at(50)).isEmpty) // 40s < 100
        #expect(firedNodes(engine.reconcile([stale(7, cooldown: 100)], now: at(120))) == [7]) // 110s ≥ 100
    }

    @Test
    func `acknowledge moves firing → acknowledged and stays quiet`() {
        var engine = AlertEngine()
        _ = engine.reconcile([stale(7)], now: at(0))
        engine.acknowledge(type: .stale, nodeNum: 7, at: at(5))
        #expect(engine.alert(type: .stale, nodeNum: 7)?.state == .acknowledged)
        #expect(engine.reconcile([stale(7)], now: at(10)).isEmpty)
    }

    @Test
    func `snooze suppresses re-fire until it expires`() {
        var engine = AlertEngine()
        _ = engine.reconcile([stale(7)], now: at(0))
        engine.snooze(type: .stale, nodeNum: 7, until: at(100))
        _ = engine.reconcile([], now: at(10)) // resolve
        #expect(engine.reconcile([stale(7)], now: at(20)).isEmpty) // within snooze window
        _ = engine.reconcile([], now: at(30))
        #expect(firedNodes(engine.reconcile([stale(7)], now: at(200))) == [7]) // snooze expired
    }

    @Test
    func `historical conditions are storm-suppressed (no live events)`() {
        var engine = AlertEngine()
        #expect(engine.reconcile([stale(7), stale(8)], now: at(0), historical: true).isEmpty)
        #expect(engine.alert(type: .stale, nodeNum: 7)?.state == .firing) // tracked silently
        let recover = engine.reconcile([stale(8)], now: at(10)) // 7 gone — never announced
        #expect(recover.isEmpty)
        #expect(engine.alert(type: .stale, nodeNum: 7)?.state == .resolved)
    }
}
