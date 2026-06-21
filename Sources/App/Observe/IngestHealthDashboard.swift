// IngestHealthDashboard — the pure derivations behind the observability section
// (G10). Given an `IngestHealth` snapshot (and the current instant, injected so
// "lag" is testable), it computes ingestion lag, throughput, decode-error rate,
// dedup rate, per-transport health and the message count. No SwiftUI, no I/O —
// every value here is unit-tested.

import Domain
import Foundation
import Observation

/// One derived metric ready to render as a tile: a label, a formatted value, a
/// unit, and a qualitative status that drives the tile tint.
public struct HealthMetric: Sendable, Equatable, Identifiable {
    /// Qualitative health, mapped to a tint by the view (kept UI-free here).
    public enum Status: Sendable, Equatable {
        case good
        case warn
        case bad
        case neutral
    }

    public let id: String
    public let label: String
    public let value: String
    public let unit: String
    public let status: Status

    public init(id: String, label: String, value: String, unit: String, status: Status) {
        self.id = id
        self.label = label
        self.value = value
        self.unit = unit
        self.status = status
    }
}

/// Pure derivations over an `IngestHealth` snapshot. A free `enum` namespace so
/// the maths is trivially testable; the `@Observable` VM below wraps it for the
/// view.
public enum IngestHealthDerivation {
    /// Nanoseconds per second, for ns-Instant → seconds conversions.
    static let nanosPerSecond: Double = 1_000_000_000

    /// Seconds between the last packet and `now` (ingestion lag). `nil` when no
    /// packet has been seen yet. Clamped at zero so a slightly-stale clock never
    /// shows negative lag.
    public static func lagSeconds(_ health: IngestHealth, now: Instant) -> Double? {
        guard let last = health.lastPacketAt else { return nil }
        let deltaNanos = now.nanosecondsSinceEpoch - last.nanosecondsSinceEpoch
        return max(0, Double(deltaNanos) / nanosPerSecond)
    }

    /// Average throughput (decoded packets / second) since the run started. `nil`
    /// when the run hasn't started or no time has elapsed.
    public static func averageThroughput(_ health: IngestHealth, now: Instant) -> Double? {
        guard let started = health.startedAt else { return nil }
        let elapsed = Double(now.nanosecondsSinceEpoch - started.nanosecondsSinceEpoch) / nanosPerSecond
        guard elapsed > 0 else { return nil }
        return Double(health.packetsDecoded) / elapsed
    }

    /// The most recent instantaneous throughput sample (msgs/sec), or 0.
    public static func currentThroughput(_ health: IngestHealth) -> Double {
        health.throughputSamples.last ?? 0
    }

    /// Fraction of frames that failed to decode, in `0...1`. Zero when no frames
    /// were processed (no errors yet, not 100% error).
    public static func decodeErrorRate(_ health: IngestHealth) -> Double {
        guard health.framesProcessed > 0 else { return 0 }
        return Double(health.decodeErrors) / Double(health.framesProcessed)
    }

    /// Decode success rate, in `0...1`. 100% with nothing processed (nothing has
    /// failed).
    public static func decodeSuccessRate(_ health: IngestHealth) -> Double {
        1 - decodeErrorRate(health)
    }

    /// Fraction of total deliveries that were duplicate re-deliveries collapsed
    /// by provenance dedup, in `0...1`. The denominator is every delivery seen
    /// (recorded observations + skipped duplicates), so 0 deliveries → 0.
    public static func dedupRate(_ health: IngestHealth) -> Double {
        let total = health.observationsRecorded + health.duplicateDeliveriesSkipped
        guard total > 0 else { return 0 }
        return Double(health.duplicateDeliveriesSkipped) / Double(total)
    }

    /// Uptime in seconds since the run started, or `nil` if not started.
    public static func uptimeSeconds(_ health: IngestHealth, now: Instant) -> Double? {
        guard let started = health.startedAt else { return nil }
        return max(0, Double(now.nanosecondsSinceEpoch - started.nanosecondsSinceEpoch) / nanosPerSecond)
    }

    /// The number of transports currently reporting connected.
    public static func connectedTransportCount(_ health: IngestHealth) -> Int {
        health.transports.count(where: \.connected)
    }

    // MARK: Tile assembly

    /// The ordered metric tiles for the dashboard, each with a qualitative status
    /// driving its tint. This is the single source of truth the view renders.
    public static func metrics(_ health: IngestHealth, now: Instant) -> [HealthMetric] {
        var tiles: [HealthMetric] = []

        // Ingestion lag — the freshness of the feed.
        if let lag = lagSeconds(health, now: now) {
            tiles.append(HealthMetric(
                id: "lag",
                label: "INGEST LAG",
                value: formatDuration(lag),
                unit: "ago",
                status: lag < 30 ? .good : (lag < 300 ? .warn : .bad)
            ))
        } else {
            tiles.append(HealthMetric(
                id: "lag", label: "INGEST LAG", value: "—", unit: "no data", status: .neutral
            ))
        }

        // Throughput — current sample, falling back to the average.
        let current = currentThroughput(health)
        let throughput = current > 0 ? current : (averageThroughput(health, now: now) ?? 0)
        tiles.append(HealthMetric(
            id: "throughput",
            label: "THROUGHPUT",
            value: String(format: "%.1f", throughput),
            unit: "msg/s",
            status: throughput > 0 ? .good : .neutral
        ))

        // Decode success — higher is better.
        let success = decodeSuccessRate(health) * 100
        tiles.append(HealthMetric(
            id: "decode",
            label: "DECODE OK",
            value: String(format: "%.1f", success),
            unit: "%",
            status: health.framesProcessed == 0 ? .neutral : (success >= 95 ? .good : (success >= 80 ? .warn : .bad))
        ))

        // Dedup rate — how much multi-gateway duplication we collapsed (good).
        tiles.append(HealthMetric(
            id: "dedup",
            label: "DUPES COLLAPSED",
            value: String(format: "%.0f", dedupRate(health) * 100),
            unit: "%",
            status: .good
        ))

        // Raw counts.
        tiles.append(HealthMetric(
            id: "packets",
            label: "PACKETS",
            value: "\(health.packetsDecoded)",
            unit: "decoded",
            status: .neutral
        ))
        tiles.append(HealthMetric(
            id: "messages",
            label: "MESSAGES",
            value: "\(health.messagesRecorded)",
            unit: "text",
            status: .neutral
        ))
        tiles.append(HealthMetric(
            id: "telemetry",
            label: "TELEMETRY",
            value: "\(health.telemetryPointsRecorded)",
            unit: "points",
            status: .neutral
        ))

        // Transport connectivity.
        let up = connectedTransportCount(health)
        let total = health.transports.count
        tiles.append(HealthMetric(
            id: "transports",
            label: "TRANSPORTS",
            value: total > 0 ? "\(up)/\(total)" : "—",
            unit: "up",
            status: total == 0 ? .neutral : (up == total ? .good : (up > 0 ? .warn : .bad))
        ))

        return tiles
    }

    /// Compact "12s" / "3m" / "1.2h" duration formatting for the lag tile.
    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        if seconds < 5400 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }
}

/// `@MainActor @Observable` view-model the section binds to. It holds the latest
/// `IngestHealth` snapshot (pushed by the live coordinator's `update(_:)`), plus
/// the injected current instant, and exposes the derived metrics for the view.
@Observable
@MainActor
public final class ObservabilityViewModel {
    /// The latest pushed snapshot.
    public private(set) var health: IngestHealth
    /// The instant used to compute lag/uptime. Updated alongside the snapshot;
    /// injectable so tests are deterministic.
    public private(set) var now: Instant

    public init(health: IngestHealth = IngestHealth(), now: Instant = Instant(nanosecondsSinceEpoch: 0)) {
        self.health = health
        self.now = now
    }

    /// Push a fresh snapshot from the live coordinator (G2). `now` defaults to the
    /// snapshot's `lastPacketAt` when not supplied, so the dashboard stays
    /// deterministic without a wall clock.
    public func update(_ health: IngestHealth, now: Instant? = nil) {
        self.health = health
        self.now = now ?? health.lastPacketAt ?? self.now
    }

    /// The derived metric tiles for the current snapshot.
    public var metrics: [HealthMetric] {
        IngestHealthDerivation.metrics(health, now: now)
    }

    /// The throughput sparkline samples.
    public var throughput: [Double] {
        health.throughputSamples
    }

    /// Per-transport health rows.
    public var transports: [TransportHealth] {
        health.transports
    }

    /// Ingestion lag in seconds, or `nil` when no packet has been seen.
    public var lagSeconds: Double? {
        IngestHealthDerivation.lagSeconds(health, now: now)
    }
}
