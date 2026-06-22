@testable import App
import Domain
import Foundation
import Persistence
import RuleEngine
import Testing

@Suite("StoreAlertSnapshotSource + management lookup (live alert adapters, Finding 7)")
struct StoreAlertAdaptersTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    private static let t0 = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    @Test
    func `snapshot maps lastHeard + the latest battery/voltage telemetry`() {
        let node = NodeRecord(
            node_num: 0xABCD,
            node_class: .fixed,
            first_seen_at: Self.t0.nanosecondsSinceEpoch,
            last_heard_at: Self.t0.nanosecondsSinceEpoch
        )
        let telemetry: [TelemetryRecord] = [
            // Time-ascending; the latest battery (40) and voltage (3.6) must win.
            TelemetryRecord(node_num: 0xABCD, t: 1, kind: .device, key: "battery_pct", value: 80),
            TelemetryRecord(node_num: 0xABCD, t: 2, kind: .device, key: "voltage", value: 4.1),
            TelemetryRecord(node_num: 0xABCD, t: 3, kind: .device, key: "battery_pct", value: 40),
            TelemetryRecord(node_num: 0xABCD, t: 4, kind: .device, key: "voltage", value: 3.6)
        ]
        let snapshot = StoreAlertSnapshotSource.snapshot(node: node, telemetry: telemetry)
        #expect(snapshot.nodeNum == 0xABCD)
        #expect(snapshot.nodeClass == .fixed)
        #expect(snapshot.lastHeard == Self.t0)
        #expect(snapshot.batteryPercent == 40)
        #expect(snapshot.voltage == 3.6)
    }

    @Test
    func `missing telemetry yields nil battery/voltage (never crashes)`() {
        let node = NodeRecord(
            node_num: 0x01,
            node_class: .mobile,
            first_seen_at: 0,
            last_heard_at: 0
        )
        let snapshot = StoreAlertSnapshotSource.snapshot(node: node, telemetry: [])
        #expect(snapshot.batteryPercent == nil)
        #expect(snapshot.voltage == nil)
    }

    @Test
    func `non-finite telemetry values are ignored (no NaN/Inf into the evaluator)`() {
        let node = NodeRecord(node_num: 0x02, node_class: .fixed, first_seen_at: 0, last_heard_at: 0)
        let telemetry: [TelemetryRecord] = [
            TelemetryRecord(node_num: 0x02, t: 1, kind: .device, key: "battery_pct", value: 55),
            // A later NaN must NOT override the prior finite reading.
            TelemetryRecord(node_num: 0x02, t: 2, kind: .device, key: "battery_pct", value: .nan)
        ]
        let snapshot = StoreAlertSnapshotSource.snapshot(node: node, telemetry: telemetry)
        #expect(snapshot.batteryPercent == 55)
    }

    @Test
    func `snapshots reads every node from the store`() async throws {
        let store = try makeStore()
        try await store.markHeard(nodeNum: 0x10, at: Self.t0)
        try await store.markHeard(nodeNum: 0x11, at: Self.t0)
        _ = try await store.appendTelemetry(
            TelemetryRecord(node_num: 0x10, t: 1, kind: .device, key: "battery_pct", value: 12)
        )
        let source = StoreAlertSnapshotSource(store: store)
        let snapshots = try await source.snapshots()
        #expect(snapshots.count == 2)
        let low = try #require(snapshots.first { $0.nodeNum == 0x10 })
        #expect(low.batteryPercent == 12)
    }

    @Test
    func `management lookup reflects the store's managed set; strangers are unowned`() async throws {
        let store = try makeStore()
        try await store.markHeard(nodeNum: 0x20, at: Self.t0)
        try await store.markHeard(nodeNum: 0x21, at: Self.t0)
        try await store.setOwnership(nodeNum: 0x20, isManaged: true)
        let lookup = await StoreAlertNodeManagementLookup(store: store)
        #expect(lookup.management(forNodeNum: 0x20).isManaged)
        #expect(!lookup.management(forNodeNum: 0x21).isManaged)
        // An unknown node is unowned (never battery/silence-alerted, ADR 0008).
        #expect(lookup.management(forNodeNum: 0x99) == .unowned)
    }

    @Test
    func `the real adapters drive the evaluator to fire a managed low-battery alert`() async throws {
        let store = try makeStore()
        // A managed node with a low battery + a global battery<20 rule.
        try await store.markHeard(nodeNum: 0x30, at: Self.t0)
        try await store.setOwnership(nodeNum: 0x30, isManaged: true)
        _ = try await store.appendTelemetry(
            TelemetryRecord(node_num: 0x30, t: 1, kind: .device, key: "battery_pct", value: 5)
        )
        try await store.upsertAlertRule(
            scope: "global", scopeID: nil, type: "battery_below",
            paramsJSON: "{\"threshold\":20}", enabled: true
        )
        let evaluator = await LiveAlertEvaluator(
            snapshots: StoreAlertSnapshotSource(store: store),
            rules: HoursToSecondsAlertRuleStore(wrapping: TestAppRuleStore(store: store)),
            management: StoreAlertNodeManagementLookup(store: store),
            sink: store,
            clock: InjectedClock(Self.t0)
        )
        let alerts = try await evaluator.evaluate()
        #expect(alerts.contains { $0.type == .batteryBelow && $0.nodeNum == 0x30 })
    }

    @Test
    func `a low-battery STRANGER never fires (ownership gate, ADR 0008)`() async throws {
        let store = try makeStore()
        // Same low battery + rule, but the node is NOT managed.
        try await store.markHeard(nodeNum: 0x31, at: Self.t0)
        _ = try await store.appendTelemetry(
            TelemetryRecord(node_num: 0x31, t: 1, kind: .device, key: "battery_pct", value: 5)
        )
        try await store.upsertAlertRule(
            scope: "global", scopeID: nil, type: "battery_below",
            paramsJSON: "{\"threshold\":20}", enabled: true
        )
        let evaluator = await LiveAlertEvaluator(
            snapshots: StoreAlertSnapshotSource(store: store),
            rules: HoursToSecondsAlertRuleStore(wrapping: TestAppRuleStore(store: store)),
            management: StoreAlertNodeManagementLookup(store: store),
            sink: store,
            clock: InjectedClock(Self.t0)
        )
        let alerts = try await evaluator.evaluate()
        #expect(!alerts.contains { $0.nodeNum == 0x31 })
    }
}

/// A minimal App-layer `AlertRuleStore` over a real store for the end-to-end test
/// (the production `MeshStoreAlertRuleStore` lives in the executable target, so the
/// App test re-derives the same mapping for global battery/voltage/stale rules).
private struct TestAppRuleStore: App.AlertRuleStore {
    let store: MeshStore

    func allRules() async throws -> [App.AlertRuleRecord] {
        try await store.allAlertRules().compactMap { record in
            guard let type = App.AlertRuleType(rawValue: record.type), record.scope == "global" else {
                return nil
            }
            let threshold = decode(record.params_json) ?? type.defaultThreshold
            return App.AlertRuleRecord(
                scope: .global,
                type: type,
                threshold: threshold,
                enabled: record.enabled
            )
        }
    }

    func upsertRule(_: App.AlertRuleRecord) async throws {}
    func deleteRule(scope _: App.AlertRuleScope, type _: App.AlertRuleType) async throws {}

    private struct Params: Codable { let threshold: Double }
    private func decode(_ json: String?) -> Double? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Params.self, from: data))?.threshold
    }
}
