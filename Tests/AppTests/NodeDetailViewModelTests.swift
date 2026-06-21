@testable import App
import Domain
import Foundation
import Persistence
import Testing

@Suite("NodeDetailViewModel (map node-detail popover)")
@MainActor
struct NodeDetailViewModelTests {
    private func seededStore() async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0x42, hexid: "!00000042", short_name: "RPT",
            long_name: "Repeater One", node_class: .fixed, hw_model: "TBEAM",
            role: "ROUTER", first_seen_at: 0, last_heard_at: 1_000_000_000, is_mine: true
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x42, t: 1, lat: 37.1, lon: -122.2
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x42, t: 5, lat: 37.4, lon: -122.0 // newer fix wins
        ))
        try await store.appendTelemetry(TelemetryRecord(
            node_num: 0x42, t: 1, kind: .device, key: "battery_pct", value: 50
        ))
        try await store.appendTelemetry(TelemetryRecord(
            node_num: 0x42, t: 9, kind: .device, key: "battery_pct", value: 62 // latest
        ))
        try await store.appendTelemetry(TelemetryRecord(
            node_num: 0x42, t: 3, kind: .device, key: "voltage", value: 3.74
        ))
        return store
    }

    @Test
    func `load surfaces identity, the latest fix and the latest telemetry`() async throws {
        let model = try await NodeDetailViewModel(store: seededStore(), nodeNum: 0x42)
        try await model.load()
        #expect(model.name == "RPT")
        #expect(model.role == "ROUTER")
        #expect(model.hardwareModel == "TBEAM")
        #expect(model.isMine)
        #expect(model.coordinate?.latitude == 37.4) // newest fix
        #expect(model.batteryPercent == 62) // newest battery reading
        #expect(model.lastHeard == Instant(nanosecondsSinceEpoch: 1_000_000_000))
    }

    @Test
    func `latestPerKey keeps the most recent reading per metric, battery first`() {
        let records = [
            TelemetryRecord(node_num: 1, t: 1, kind: .device, key: "voltage", value: 3.5),
            TelemetryRecord(node_num: 1, t: 2, kind: .device, key: "battery_pct", value: 40),
            TelemetryRecord(node_num: 1, t: 9, kind: .device, key: "battery_pct", value: 41)
        ]
        let latest = NodeDetailViewModel.latestPerKey(records)
        #expect(latest.map(\.key) == ["battery_pct", "voltage"]) // battery ranks first
        #expect(latest.first?.value == 41) // newest battery
    }

    @Test
    func `telemetry reading formats value with its unit`() {
        let battery = TelemetryReading(kind: .device, key: "battery_pct", value: 62, time: 0)
        #expect(battery.formatted == "62%")
        let voltage = TelemetryReading(kind: .device, key: "voltage", value: 3.74, time: 0)
        #expect(voltage.formatted == "3.74 V")
    }

    @Test
    func `relative last-heard buckets coarsely`() {
        let now = Date(timeIntervalSince1970: 100_000)
        func ago(_ seconds: Double) -> Instant {
            Instant(nanosecondsSinceEpoch: Int64((now.timeIntervalSince1970 - seconds) * 1e9))
        }
        #expect(NodeDetailPopover.relativeLastHeard(ago(10), now: now) == "just now")
        #expect(NodeDetailPopover.relativeLastHeard(ago(120), now: now) == "2m ago")
        #expect(NodeDetailPopover.relativeLastHeard(ago(7200), now: now) == "2h ago")
        #expect(NodeDetailPopover.relativeLastHeard(ago(172_800), now: now) == "2d ago")
    }
}
