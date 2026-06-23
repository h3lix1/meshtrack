// AlertRuleThresholdUnitsTests — Finding 11 (P2).
//
// The Alerts editor shows the `stale` threshold in HOURS (default 24), but the
// canonical value the rule engine evaluates and the database persists is SECONDS:
// `RuleEvaluator` compares a node's silence in seconds directly to the threshold.
// Without conversion a 24-hour rule fires after 24 seconds. These tests pin the
// hours↔seconds conversion at the storage boundary (`HoursToSecondsAlertRuleStore`),
// the pure unit helpers on `AlertRuleType`, and that the canonical seconds value
// drives `RuleEvaluator` to the intended 24-hour behaviour.

@testable import App
import Domain
import RuleEngine
import Testing

@Suite("Alert rule threshold units (hours ↔ seconds, Finding 11)")
@MainActor
struct AlertRuleThresholdUnitsTests {
    // MARK: Pure unit conversion on the type

    @Test
    func `stale converts editor hours to canonical seconds and back`() {
        // 24 editor hours == 86,400 canonical seconds.
        #expect(AlertRuleType.stale.canonicalThreshold(fromEditor: 24) == 86400)
        #expect(AlertRuleType.stale.editorThreshold(fromCanonical: 86400) == 24)
        // Round-trips losslessly across a range of editor values.
        for hours in [1.0, 6, 12, 24, 48, 720] {
            let seconds = AlertRuleType.stale.canonicalThreshold(fromEditor: hours)
            #expect(AlertRuleType.stale.editorThreshold(fromCanonical: seconds) == hours)
        }
    }

    @Test
    func `battery and voltage thresholds are unit-identical (no conversion)`() {
        // % and V are the same in editor and canonical domains.
        #expect(AlertRuleType.batteryBelow.canonicalThreshold(fromEditor: 20) == 20)
        #expect(AlertRuleType.batteryBelow.editorThreshold(fromCanonical: 20) == 20)
        #expect(AlertRuleType.voltageBelow.canonicalThreshold(fromEditor: 3.3) == 3.3)
        #expect(AlertRuleType.voltageBelow.editorThreshold(fromCanonical: 3.3) == 3.3)
    }

    // MARK: Decorator persists canonical seconds, surfaces editor hours

    @Test
    func `the 24h editor value persists as 86,400 seconds in the wrapped store`() async throws {
        let inner = InMemoryAlertRuleStore()
        let store = HoursToSecondsAlertRuleStore(wrapping: inner)

        // The editor upserts a 24-HOUR stale rule…
        try await store.upsertRule(AlertRuleRecord(scope: .global, type: .stale, threshold: 24))

        // …and the underlying (persisted) store holds canonical SECONDS.
        let persisted = try #require(try await inner.allRules().first { $0.type == .stale })
        #expect(persisted.threshold == 86400)
    }

    @Test
    func `reading back through the decorator round-trips 24h in the editor`() async throws {
        // Seed the inner store with the canonical seconds value the DB would hold.
        let inner = InMemoryAlertRuleStore([
            AlertRuleRecord(scope: .global, type: .stale, threshold: 86400)
        ])
        let store = HoursToSecondsAlertRuleStore(wrapping: inner)

        let editor = try #require(try await store.allRules().first { $0.type == .stale })
        #expect(editor.threshold == 24)
    }

    @Test
    func `battery and voltage records pass through the decorator unchanged`() async throws {
        let inner = InMemoryAlertRuleStore()
        let store = HoursToSecondsAlertRuleStore(wrapping: inner)

        try await store.upsertRule(AlertRuleRecord(scope: .global, type: .batteryBelow, threshold: 20))
        try await store.upsertRule(AlertRuleRecord(scope: .node(7), type: .voltageBelow, threshold: 3.3))

        let persisted = try await inner.allRules()
        #expect(persisted.first { $0.type == .batteryBelow }?.threshold == 20)
        let voltage = try #require(persisted.first { $0.type == .voltageBelow }?.threshold)
        #expect(abs(voltage - 3.3) < 0.0001)

        // …and they come back unchanged through the editor read path.
        let editor = try await store.allRules()
        #expect(editor.first { $0.type == .batteryBelow }?.threshold == 20)
    }

    // MARK: End-to-end through the editor view model

    @Test
    func `editing 24h via the view model persists canonical seconds and reloads 24h`() async throws {
        let inner = InMemoryAlertRuleStore()
        let store = HoursToSecondsAlertRuleStore(wrapping: inner)
        let viewModel = AlertsConfigViewModel(rules: store)
        await viewModel.load()

        // The editor works in hours: add the default stale rule (24h) globally.
        await viewModel.addRule(type: .stale, scope: .global)
        #expect(viewModel.record(scope: .global, type: .stale)?.threshold == 24)

        // Persisted canonically as seconds (what RuleEvaluator compares against).
        let persisted = try #require(try await inner.allRules().first { $0.type == .stale })
        #expect(persisted.threshold == 86400)

        // A fresh editor over the same decorator reads 24h back.
        let reader = AlertsConfigViewModel(rules: store)
        await reader.load()
        #expect(reader.record(scope: .global, type: .stale)?.threshold == 24)
    }

    // MARK: The canonical seconds value drives RuleEvaluator correctly

    @Test
    func `the persisted 86,400s stale threshold fires after 24h of silence, not 24s`() async throws {
        let inner = InMemoryAlertRuleStore()
        let store = HoursToSecondsAlertRuleStore(wrapping: inner)
        // Editor saves a 24-hour rule.
        try await store.upsertRule(AlertRuleRecord(scope: .global, type: .stale, threshold: 24))

        // Build the engine's RuleSet from the *persisted* (canonical seconds) value.
        let persisted = try #require(try await inner.allRules().first { $0.type == .stale })
        let rules = RuleSet([AlertRule(type: .stale, scope: .global, threshold: persisted.threshold)])

        let snapshot = NodeSnapshot(
            nodeNum: 7, nodeClass: .fixed,
            lastHeard: Instant.epoch, expectedInterval: 900
        )
        let managed = NodeManagement(isManaged: true)

        // 24 SECONDS of silence must NOT fire (the bug fired here).
        let after24s = RuleEvaluator.conditions(
            for: snapshot, rules: rules, now: Instant.epoch.adding(seconds: 24), management: managed
        )
        #expect(after24s.isEmpty)

        // Just past 24 HOURS of silence DOES fire stale.
        let after24h = RuleEvaluator.conditions(
            for: snapshot, rules: rules,
            now: Instant.epoch.adding(seconds: 86400 + 1), management: managed
        )
        #expect(after24h.map(\.type) == [.stale])
    }
}
