@testable import App
import Domain
import Persistence
import Testing

@Suite("TelemetryChartsViewModel")
@MainActor
struct TelemetryChartsViewModelTests {
    private let nodeNum: Int64 = 0xA1B2_C3D4

    /// A store with `count` battery + voltage samples at hourly spacing ending at
    /// `endNanos`, plus a temperature sample, for one node.
    private func seededStore(endNanos: Int64, count: Int) async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let hour: Int64 = 3_600_000_000_000
        for i in 0 ..< count {
            let t = endNanos - Int64(i) * hour
            try await store.appendTelemetry(
                TelemetryRecord(node_num: nodeNum, t: t, kind: .device, key: "battery_pct", value: Double(80 + i))
            )
            try await store.appendTelemetry(
                TelemetryRecord(node_num: nodeNum, t: t, kind: .device, key: "voltage", value: 3.7)
            )
        }
        try await store.appendTelemetry(
            TelemetryRecord(node_num: nodeNum, t: endNanos, kind: .environment, key: "temp", value: 21.5)
        )
        return store
    }

    @Test
    func `load reads raw device and environment series within the 24h window`() async throws {
        let now: Int64 = 1_000 * 3_600_000_000_000
        let store = try await seededStore(endNanos: now, count: 6)
        let viewModel = TelemetryChartsViewModel(
            store: store, nodeNum: nodeNum, now: { Instant(nanosecondsSinceEpoch: now) }
        )
        try await viewModel.load()

        #expect(viewModel.resolution == .raw)
        #expect(viewModel.hasData)
        let device = Set(viewModel.deviceSeries.map(\.metric.key))
        #expect(device.contains("battery_pct"))
        #expect(device.contains("voltage"))
        #expect(viewModel.environmentSeries.map(\.metric.key) == ["temp"])
        // Battery series is ordered by time ascending.
        let battery = try #require(viewModel.deviceSeries.first { $0.metric.key == "battery_pct" })
        #expect(battery.points.map(\.time).sorted() == battery.points.map(\.time))
    }

    @Test
    func `the 24h window excludes older raw samples`() async throws {
        let now: Int64 = 1_000 * 3_600_000_000_000
        // 30 hourly samples — only the last 24 fall inside the 24h window.
        let store = try await seededStore(endNanos: now, count: 30)
        let viewModel = TelemetryChartsViewModel(
            store: store, nodeNum: nodeNum, now: { Instant(nanosecondsSinceEpoch: now) }
        )
        try await viewModel.select(.day)
        let battery = try #require(viewModel.deviceSeries.first { $0.metric.key == "battery_pct" })
        // sample at offset i is at now - i*hour; window lower bound is now-24h, so
        // offsets 0…24 inclusive qualify (25 samples).
        #expect(battery.points.count == 25)
    }

    @Test
    func `week range reads the hourly rollup resolution`() async throws {
        let now: Int64 = 10_000 * 3_600_000_000_000
        let store = try await seededStore(endNanos: now - 3_600_000_000_000, count: 48)
        // Produce rollups for complete buckets before `now`.
        try await store.rollupTelemetry(now: Instant(nanosecondsSinceEpoch: now))
        let viewModel = TelemetryChartsViewModel(
            store: store, nodeNum: nodeNum, now: { Instant(nanosecondsSinceEpoch: now) }
        )
        try await viewModel.select(.week)
        #expect(viewModel.resolution == .hourly)
        #expect(viewModel.hasData)
        let battery = try #require(viewModel.deviceSeries.first { $0.metric.key == "battery_pct" })
        // Rollup points carry the min/max band.
        #expect(battery.points.allSatisfy { $0.minValue != nil })
    }

    @Test
    func `load on an empty store yields no data`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let viewModel = TelemetryChartsViewModel(
            store: store, nodeNum: nodeNum, now: { Instant(nanosecondsSinceEpoch: 0) }
        )
        try await viewModel.load()
        #expect(!viewModel.hasData)
        #expect(viewModel.deviceSeries.isEmpty)
    }
}
