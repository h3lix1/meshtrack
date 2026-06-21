// TelemetrySeries — the PURE telemetry-to-chart-series core (Phase 7 G4).
//
// Turns raw `TelemetryRecord`s and downsampled `TelemetryRollupRecord`s into a
// uniform `[TelemetryPoint]` per metric, so the Swift Charts view is a dumb
// renderer. The metric catalogue (`TelemetryMetric`) names the (kind, key) pairs
// the dashboard charts — battery_pct, voltage, channel_util, air_util_tx, temp,
// humidity, pressure — with their axis units and sensible value domains.
//
// Raw vs. rollup: short ranges read the raw series; long ranges read the hourly
// or daily rollups (fewer points, same shape). The store owns the rollup SQL;
// this layer only reshapes what it returns.

import Domain
import Persistence

/// One plotted sample: a time (nanoseconds since epoch) and a value, plus the
/// rollup band (min/max) when the point came from a downsample (nil for raw).
public struct TelemetryPoint: Sendable, Equatable, Identifiable {
    public let time: Int64
    public let value: Double
    public let minValue: Double?
    public let maxValue: Double?

    public var id: Int64 { time }

    /// Seconds since the Unix epoch — convenient for `Date(timeIntervalSince1970:)`
    /// at the SwiftUI boundary without dragging Foundation into this core.
    public var secondsSinceEpoch: Double { Double(time) / 1_000_000_000 }

    public init(time: Int64, value: Double, minValue: Double? = nil, maxValue: Double? = nil) {
        self.time = time
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
    }
}

/// A named telemetry metric the dashboard charts: its storage coordinates
/// (`kind` + `key`), a display label, axis unit, and an optional fixed y-domain.
public struct TelemetryMetric: Sendable, Equatable, Identifiable, Hashable {
    public let key: String
    public let kind: TelemetryKind
    public let label: String
    public let unit: String
    /// A fixed y-axis domain when the metric has natural bounds (battery 0…100,
    /// utilisation 0…100). `nil` lets the chart auto-scale (voltage, temp…).
    public let domain: ClosedRange<Double>?

    public var id: String { "\(kind.rawValue):\(key)" }

    public init(
        key: String,
        kind: TelemetryKind,
        label: String,
        unit: String,
        domain: ClosedRange<Double>? = nil
    ) {
        self.key = key
        self.kind = kind
        self.label = label
        self.unit = unit
        self.domain = domain
    }
}

public extension TelemetryMetric {
    static let batteryPercent = TelemetryMetric(
        key: "battery_pct", kind: .device, label: "Battery", unit: "%", domain: 0 ... 100
    )
    static let voltage = TelemetryMetric(
        key: "voltage", kind: .device, label: "Voltage", unit: "V"
    )
    static let channelUtil = TelemetryMetric(
        key: "channel_util", kind: .device, label: "Channel Util", unit: "%", domain: 0 ... 100
    )
    static let airUtilTx = TelemetryMetric(
        key: "air_util_tx", kind: .device, label: "Air Util TX", unit: "%", domain: 0 ... 100
    )
    static let temperature = TelemetryMetric(
        key: "temp", kind: .environment, label: "Temperature", unit: "°C"
    )
    static let humidity = TelemetryMetric(
        key: "humidity", kind: .environment, label: "Humidity", unit: "%", domain: 0 ... 100
    )
    static let pressure = TelemetryMetric(
        key: "pressure", kind: .environment, label: "Pressure", unit: "hPa"
    )

    /// Device metrics shown on the device-telemetry tab.
    static let deviceMetrics: [TelemetryMetric] = [batteryPercent, voltage, channelUtil, airUtilTx]
    /// Environment metrics shown on the environment-telemetry tab.
    static let environmentMetrics: [TelemetryMetric] = [temperature, humidity, pressure]
    /// Everything the dashboard knows how to chart.
    static let all: [TelemetryMetric] = deviceMetrics + environmentMetrics
}

/// How far back to chart, and which storage resolution to read.
public enum TelemetryRange: String, Sendable, CaseIterable, Identifiable {
    case sixHours
    case day
    case week
    case month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sixHours: "6H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }

    /// Window length in nanoseconds.
    public var nanoseconds: Int64 {
        switch self {
        case .sixHours: 6 * 3_600_000_000_000
        case .day: 24 * 3_600_000_000_000
        case .week: 7 * 86_400_000_000_000
        case .month: 30 * 86_400_000_000_000
        }
    }

    /// Which resolution best serves this range. Short ranges use raw samples;
    /// multi-day ranges use the hourly rollup; a month uses the daily rollup.
    public var resolution: TelemetryResolution {
        switch self {
        case .sixHours, .day: .raw
        case .week: .hourly
        case .month: .daily
        }
    }
}

/// The storage table a series is sourced from.
public enum TelemetryResolution: Sendable, Equatable {
    case raw
    case hourly
    case daily
}

public extension TelemetrySeries {
    /// A built series ready for the chart: the metric, its points, and the
    /// resolution they came from (for the "showing hourly averages" caption).
    struct Built: Sendable, Equatable, Identifiable {
        public let metric: TelemetryMetric
        public let points: [TelemetryPoint]
        public let resolution: TelemetryResolution

        public var id: String { metric.id }
        public var isEmpty: Bool { points.isEmpty }

        public init(metric: TelemetryMetric, points: [TelemetryPoint], resolution: TelemetryResolution) {
            self.metric = metric
            self.points = points
            self.resolution = resolution
        }
    }
}

/// Pure reshaping of telemetry rows into chart points.
public enum TelemetrySeries {
    /// Raw points for `metric` within `[lowerBoundNanos, ...]`, ordered by time.
    /// Rows are pre-filtered to the metric's `kind`+`key`; this just maps + sorts
    /// + applies the lower-bound window.
    public static func rawPoints(
        _ records: [TelemetryRecord],
        metric: TelemetryMetric,
        sinceNanos lowerBound: Int64
    ) -> [TelemetryPoint] {
        records
            .filter { $0.kind == metric.kind && $0.key == metric.key && $0.t >= lowerBound }
            .sorted { $0.t < $1.t }
            .map { TelemetryPoint(time: $0.t, value: $0.value) }
    }

    /// Rollup points for `metric` within the window, ordered by bucket. The
    /// average is plotted; min/max ride along as the band.
    public static func rollupPoints(
        _ records: [TelemetryRollupRecord],
        metric: TelemetryMetric,
        sinceNanos lowerBound: Int64
    ) -> [TelemetryPoint] {
        records
            .filter { $0.kind == metric.kind && $0.key == metric.key && $0.bucket >= lowerBound }
            .sorted { $0.bucket < $1.bucket }
            .map {
                TelemetryPoint(
                    time: $0.bucket,
                    value: $0.avg_value,
                    minValue: $0.min_value,
                    maxValue: $0.max_value
                )
            }
    }

    /// All metrics in `metrics` that have at least one raw point in the window.
    public static func buildRaw(
        _ records: [TelemetryRecord],
        metrics: [TelemetryMetric],
        sinceNanos lowerBound: Int64
    ) -> [Built] {
        metrics.compactMap { metric in
            let points = rawPoints(records, metric: metric, sinceNanos: lowerBound)
            guard !points.isEmpty else { return nil }
            return Built(metric: metric, points: points, resolution: .raw)
        }
    }

    /// All metrics with at least one rollup point in the window.
    public static func buildRollup(
        _ records: [TelemetryRollupRecord],
        metrics: [TelemetryMetric],
        resolution: TelemetryResolution,
        sinceNanos lowerBound: Int64
    ) -> [Built] {
        metrics.compactMap { metric in
            let points = rollupPoints(records, metric: metric, sinceNanos: lowerBound)
            guard !points.isEmpty else { return nil }
            return Built(metric: metric, points: points, resolution: resolution)
        }
    }
}
