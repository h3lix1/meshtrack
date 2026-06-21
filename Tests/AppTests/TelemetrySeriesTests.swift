@testable import App
import Domain
import Foundation
import Persistence
import Testing

@Suite("TelemetrySeries")
struct TelemetrySeriesTests {
    private func raw(_ key: String, _ kind: TelemetryKind, t: Int64, value: Double) -> TelemetryRecord {
        TelemetryRecord(node_num: 1, t: t, kind: kind, key: key, value: value)
    }

    // `TelemetryRollupRecord` is read-only (written by the rollup SQL) and exposes
    // no public memberwise init, so we decode one through Codable for the test.
    private func rollup(
        _ key: String,
        _ kind: TelemetryKind,
        bucket: Int64,
        avg: Double,
        min: Double,
        max: Double
    ) throws -> TelemetryRollupRecord {
        let json = """
        {"node_num":1,"bucket":\(bucket),"kind":"\(kind.rawValue)","key":"\(key)",
         "min_value":\(min),"max_value":\(max),"avg_value":\(avg),"sample_count":4}
        """
        return try JSONDecoder().decode(TelemetryRollupRecord.self, from: Data(json.utf8))
    }

    // MARK: Range

    @Test
    func `ranges map to the right resolution and window`() {
        #expect(TelemetryRange.sixHours.resolution == .raw)
        #expect(TelemetryRange.day.resolution == .raw)
        #expect(TelemetryRange.week.resolution == .hourly)
        #expect(TelemetryRange.month.resolution == .daily)
        #expect(TelemetryRange.day.nanoseconds == 24 * 3_600_000_000_000)
    }

    // MARK: Raw points

    @Test
    func `raw points filter by metric and window, ordered by time`() {
        let records = [
            raw("battery_pct", .device, t: 300, value: 90),
            raw("battery_pct", .device, t: 100, value: 95),
            raw("battery_pct", .device, t: 50, value: 99), // before window
            raw("voltage", .device, t: 200, value: 3.9) // wrong metric
        ]
        let points = TelemetrySeries.rawPoints(records, metric: .batteryPercent, sinceNanos: 100)
        #expect(points.map(\.time) == [100, 300])
        #expect(points.map(\.value) == [95, 90])
        #expect(points.allSatisfy { $0.minValue == nil })
    }

    @Test
    func `raw points distinguish keys that share a kind`() {
        let records = [
            raw("battery_pct", .device, t: 1, value: 90),
            raw("voltage", .device, t: 2, value: 3.7)
        ]
        #expect(TelemetrySeries.rawPoints(records, metric: .voltage, sinceNanos: 0).map(\.value) == [3.7])
    }

    // MARK: Rollup points

    @Test
    func `rollup points carry the min/max band and plot the average`() throws {
        let records = [
            try rollup("temp", .environment, bucket: 200, avg: 21, min: 18, max: 24),
            try rollup("temp", .environment, bucket: 100, avg: 19, min: 17, max: 22)
        ]
        let points = TelemetrySeries.rollupPoints(records, metric: .temperature, sinceNanos: 0)
        #expect(points.map(\.time) == [100, 200])
        #expect(points.map(\.value) == [19, 21])
        #expect(points[0].minValue == 17)
        #expect(points[1].maxValue == 24)
    }

    // MARK: Build

    @Test
    func `buildRaw drops metrics with no points in the window`() {
        let records = [
            raw("battery_pct", .device, t: 100, value: 90),
            raw("voltage", .device, t: 5, value: 3.7) // before window — dropped
        ]
        let built = TelemetrySeries.buildRaw(
            records, metrics: TelemetryMetric.deviceMetrics, sinceNanos: 50
        )
        #expect(built.map(\.metric.key) == ["battery_pct"])
        #expect(built.first?.resolution == .raw)
    }

    @Test
    func `buildRollup tags the supplied resolution`() throws {
        let records = [try rollup("humidity", .environment, bucket: 100, avg: 55, min: 50, max: 60)]
        let built = TelemetrySeries.buildRollup(
            records, metrics: TelemetryMetric.environmentMetrics, resolution: .daily, sinceNanos: 0
        )
        #expect(built.map(\.metric.key) == ["humidity"])
        #expect(built.first?.resolution == .daily)
    }

    @Test
    func `metric catalogue exposes the expected keys and domains`() {
        #expect(TelemetryMetric.batteryPercent.domain == 0 ... 100)
        #expect(TelemetryMetric.voltage.domain == nil)
        #expect(TelemetryMetric.all.map(\.key).contains("pressure"))
        #expect(TelemetryMetric.deviceMetrics.count == 4)
    }
}
