// TelemetryChartsViewModel — store-backed telemetry charts for one node (Phase 7
// G4). Replaces the sample-fed `TelemetryChartView`: it reads raw telemetry and
// the hourly/daily rollups from the store, reshapes them with the pure
// `TelemetrySeries` core, and exposes ready-to-plot device + environment series
// for the Swift Charts view. Range selection drives both the time window and the
// storage resolution (raw for ≤24h, hourly for a week, daily for a month).
//
// @MainActor @Observable, VM-over-store; the reshaping is pure and tested, the
// loading is exercised over an in-memory `MeshStore`.

import Domain
import Foundation
import Observation
import Persistence

@Observable
@MainActor
public final class TelemetryChartsViewModel {
    public let nodeNum: Int64

    /// The selected time range; changing it re-loads on the next `load()`.
    public var range: TelemetryRange = .day

    /// Device-telemetry series (battery, voltage, channel util, air util tx).
    public private(set) var deviceSeries: [TelemetrySeries.Built] = []
    /// Environment-telemetry series (temp, humidity, pressure).
    public private(set) var environmentSeries: [TelemetrySeries.Built] = []
    /// The resolution the current series were read at (for the caption).
    public private(set) var resolution: TelemetryResolution = .raw
    /// Whether at least one `load()` has completed, so the view can tell a genuinely
    /// empty node ("no telemetry yet") from one that simply hasn't loaded yet.
    public private(set) var loaded = false

    @ObservationIgnored private let store: MeshStore
    /// Injected clock so the window's lower bound is deterministic in tests.
    @ObservationIgnored private let now: @Sendable () -> Instant

    /// System wall-clock as an `Instant` (the production default for `now`).
    public static let systemNow: @Sendable () -> Instant = {
        Instant(nanosecondsSinceEpoch: Int64(Date().timeIntervalSince1970 * 1_000_000_000))
    }

    public init(
        store: MeshStore,
        nodeNum: Int64,
        now: @escaping @Sendable () -> Instant = TelemetryChartsViewModel.systemNow
    ) {
        self.store = store
        self.nodeNum = nodeNum
        self.now = now
    }

    /// Whether either series collection has any data to draw.
    public var hasData: Bool {
        !deviceSeries.isEmpty || !environmentSeries.isEmpty
    }

    /// Select a range and reload in one call (for the range picker).
    public func select(_ range: TelemetryRange) async throws {
        self.range = range
        try await load()
    }

    /// Load both series collections for the current range from the store.
    public func load() async throws {
        let lowerBound = now().nanosecondsSinceEpoch - range.nanoseconds
        resolution = range.resolution
        switch range.resolution {
        case .raw:
            let records = try await store.telemetry(forNode: nodeNum)
            deviceSeries = TelemetrySeries.buildRaw(
                records, metrics: TelemetryMetric.deviceMetrics, sinceNanos: lowerBound
            )
            environmentSeries = TelemetrySeries.buildRaw(
                records, metrics: TelemetryMetric.environmentMetrics, sinceNanos: lowerBound
            )
        case .hourly:
            let records = try await store.hourlyTelemetry(forNode: nodeNum)
            buildFromRollups(records, resolution: .hourly, lowerBound: lowerBound)
        case .daily:
            let records = try await store.dailyTelemetry(forNode: nodeNum)
            buildFromRollups(records, resolution: .daily, lowerBound: lowerBound)
        }
        loaded = true
    }

    private func buildFromRollups(
        _ records: [TelemetryRollupRecord],
        resolution: TelemetryResolution,
        lowerBound: Int64
    ) {
        deviceSeries = TelemetrySeries.buildRollup(
            records, metrics: TelemetryMetric.deviceMetrics, resolution: resolution, sinceNanos: lowerBound
        )
        environmentSeries = TelemetrySeries.buildRollup(
            records,
            metrics: TelemetryMetric.environmentMetrics,
            resolution: resolution,
            sinceNanos: lowerBound
        )
    }
}
