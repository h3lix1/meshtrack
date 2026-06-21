// NodeDetailViewModel — backs the node-detail popover the map opens when a marker is
// tapped (Task 5). It reads the store for one node: identity (name, role, hardware),
// liveness (last heard), the latest position fix, and the most-recent device telemetry
// (battery, voltage, channel/air utilisation). @MainActor @Observable; the store reads
// are async and unit-tested over an in-memory store.
//
// It deliberately mirrors NodeAnalyticsViewModel's display-name resolution and store
// shape so the popover's "More Details" can hand the SAME nodeNum to
// NodeAnalyticsViewModel for the fuller per-node view (Task 6) without re-deriving it.

import Domain
import Foundation
import Observation
import Persistence

@Observable
@MainActor
public final class NodeDetailViewModel {
    public let nodeNum: Int64

    public private(set) var name: String?
    public private(set) var role: String?
    public private(set) var hardwareModel: String?
    public private(set) var isMine = false
    public private(set) var isManaged = false
    /// Last-heard wall-clock instant (from the node record), or nil if unknown.
    public private(set) var lastHeard: Instant?
    /// The latest position fix's coordinate, or nil if the node has never reported one.
    public private(set) var coordinate: GeoPoint?
    /// The most-recent value seen per telemetry metric key (battery_pct, voltage, …).
    public private(set) var latestTelemetry: [TelemetryReading] = []

    @ObservationIgnored private let store: MeshStore

    public init(store: MeshStore, nodeNum: Int64) {
        self.store = store
        self.nodeNum = nodeNum
    }

    /// The best-effort battery percentage (the latest `battery_pct` reading), for the
    /// popover header.
    public var batteryPercent: Double? {
        latestTelemetry.first { $0.key == "battery_pct" }?.value
    }

    /// Load the node's identity, position and latest telemetry from the store.
    public func load() async throws {
        if let record = try await store.fetchNode(nodeNum: nodeNum) {
            name = NetworkViewModel.displayName(record)
            role = record.role
            hardwareModel = record.hw_model
            isMine = record.is_mine
            isManaged = record.is_managed
            lastHeard = Instant(nanosecondsSinceEpoch: record.last_heard_at)
        }

        let fixes = try await store.positionFixes(forNode: nodeNum)
        if let latest = fixes.max(by: { $0.t < $1.t }) {
            coordinate = GeoPoint(latitude: latest.lat, longitude: latest.lon)
        }

        let telemetry = try await store.telemetry(forNode: nodeNum)
        latestTelemetry = Self.latestPerKey(telemetry)
    }

    /// The most-recent reading for each (kind, key) telemetry series, sorted by a
    /// stable display order so the popover reads consistently.
    static func latestPerKey(_ records: [TelemetryRecord]) -> [TelemetryReading] {
        var latestByKey: [String: TelemetryRecord] = [:]
        for record in records {
            if let existing = latestByKey[record.key], existing.t >= record.t { continue }
            latestByKey[record.key] = record
        }
        return latestByKey.values
            .map { TelemetryReading(kind: $0.kind, key: $0.key, value: $0.value, time: $0.t) }
            .sorted { lhs, rhs in
                let lhsRank = Self.displayRank(lhs.key)
                let rhsRank = Self.displayRank(rhs.key)
                return lhsRank == rhsRank ? lhs.key < rhs.key : lhsRank < rhsRank
            }
    }

    /// Preferred ordering: battery first, then voltage, then everything else.
    private static func displayRank(_ key: String) -> Int {
        switch key {
        case "battery_pct": 0
        case "voltage": 1
        case "channel_util": 2
        case "air_util_tx": 3
        default: 4
        }
    }
}

/// One latest telemetry reading for the detail popover.
public struct TelemetryReading: Identifiable, Equatable, Sendable {
    public var id: String {
        key
    }

    public let kind: TelemetryKind
    public let key: String
    public let value: Double
    /// Reading time (ns since epoch).
    public let time: Int64

    public init(kind: TelemetryKind, key: String, value: Double, time: Int64) {
        self.kind = kind
        self.key = key
        self.value = value
        self.time = time
    }

    /// A short human label for the metric key.
    public var label: String {
        switch key {
        case "battery_pct": "Battery"
        case "voltage": "Voltage"
        case "channel_util": "Channel Util"
        case "air_util_tx": "Air Util TX"
        case "temp": "Temperature"
        case "humidity": "Humidity"
        case "pressure": "Pressure"
        default: key
        }
    }

    /// The metric's unit suffix (empty for unitless keys).
    public var unit: String {
        switch key {
        case "battery_pct", "channel_util", "air_util_tx", "humidity": "%"
        case "voltage": "V"
        case "temp": "°C"
        case "pressure": "hPa"
        default: ""
        }
    }

    /// The value formatted with its unit, e.g. "62%" or "3.74 V". `%` hugs the number;
    /// other units get a thin space.
    public var formatted: String {
        let number = value.rounded() == value
            ? String(Int(value))
            : String(format: "%.2f", value)
        switch unit {
        case "": return number
        case "%": return number + unit
        default: return number + " " + unit
        }
    }
}
