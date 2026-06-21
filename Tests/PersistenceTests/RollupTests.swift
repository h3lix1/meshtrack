import Domain
import Foundation
@testable import Persistence
import Testing

@Suite("Telemetry rollups + retention (SPEC §5)")
struct RollupTests {
    private let hour: Int64 = 3_600_000_000_000
    private let day: Int64 = 86_400_000_000_000

    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    private func sample(_ node: Int64, t: Int64, key: String, value: Double) -> TelemetryRecord {
        TelemetryRecord(node_num: node, t: t, kind: .device, key: key, value: value)
    }

    @Test
    func `rollup aggregates a complete hourly bucket (min/max/avg/count)`() async throws {
        let store = try makeStore()
        try await store.appendTelemetry(sample(7, t: 100, key: "battery_pct", value: 80))
        try await store.appendTelemetry(sample(7, t: 200, key: "battery_pct", value: 90))
        try await store.appendTelemetry(sample(7, t: 300, key: "battery_pct", value: 100))
        try await store.rollupTelemetry(now: Instant(nanosecondsSinceEpoch: 2 * hour)) // hour-0 complete

        let rows = try await store.hourlyTelemetry(forNode: 7)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.bucket == 0)
        #expect(row.min_value == 80)
        #expect(row.max_value == 100)
        #expect(row.avg_value == 90)
        #expect(row.sample_count == 3)
    }

    @Test
    func `the current (incomplete) bucket is not rolled up`() async throws {
        let store = try makeStore()
        try await store.appendTelemetry(sample(7, t: hour + 100, key: "voltage", value: 3.9))
        try await store.rollupTelemetry(now: Instant(nanosecondsSinceEpoch: hour + 500)) // hour-1 incomplete
        #expect(try await store.hourlyTelemetry(forNode: 7).isEmpty)
    }

    @Test
    func `rollup is idempotent across runs`() async throws {
        let store = try makeStore()
        try await store.appendTelemetry(sample(7, t: 100, key: "battery_pct", value: 50))
        let now = Instant(nanosecondsSinceEpoch: 2 * hour)
        try await store.rollupTelemetry(now: now)
        try await store.rollupTelemetry(now: now)
        #expect(try await store.hourlyTelemetry(forNode: 7).count == 1)
    }

    @Test
    func `pruning raw telemetry keeps the rollups (SPEC §5 retention)`() async throws {
        let store = try makeStore()
        try await store.appendTelemetry(sample(7, t: 100, key: "battery_pct", value: 50))
        try await store.rollupTelemetry(now: Instant(nanosecondsSinceEpoch: 2 * hour))
        try await store.pruneRawTelemetry(olderThan: Instant(nanosecondsSinceEpoch: hour))
        #expect(try await store.telemetry(forNode: 7).isEmpty) // raw gone
        #expect(try await store.hourlyTelemetry(forNode: 7).count == 1) // rollup survives
    }

    @Test
    func `daily rollups aggregate across hours`() async throws {
        let store = try makeStore()
        try await store.appendTelemetry(sample(7, t: 100, key: "battery_pct", value: 40))
        try await store.appendTelemetry(sample(7, t: hour + 100, key: "battery_pct", value: 60))
        try await store.rollupTelemetry(now: Instant(nanosecondsSinceEpoch: 2 * day))
        let daily = try await store.dailyTelemetry(forNode: 7)
        #expect(daily.count == 1)
        #expect(daily.first?.avg_value == 50)
        #expect(daily.first?.sample_count == 2)
    }
}
