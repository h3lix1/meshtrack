// GRDB record types for schema v1 (SPEC §5).
//
// Property names match column names exactly (snake_case) so no CodingKeys are
// needed. Timestamps are stored as Int64 nanoseconds (Domain.Instant's raw
// value); the MeshStore API converts to/from `Instant` at the boundary, keeping
// these records driver-only and the Domain pure. TEXT-backed enums live in
// Schema.swift.

import Domain
import GRDB

// swiftlint:disable identifier_name
// Justification: record properties mirror SQLite column names (snake_case, SPEC
// §5) so Codable maps them to columns with zero CodingKeys boilerplate. The
// naming style here is deliberately the database's, not Swift's — scoped to this
// adapter file only.

/// `node` — identity + liveness. Keyed by numeric `node_num` (SPEC §2.1).
public struct NodeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = Table.node
    public var node_num: Int64
    public var hexid: String?
    public var short_name: String?
    public var long_name: String?
    public var node_class: NodeClass
    public var hw_model: String?
    public var role: String?
    public var first_seen_at: Int64
    public var last_heard_at: Int64

    public init(
        node_num: Int64,
        hexid: String? = nil,
        short_name: String? = nil,
        long_name: String? = nil,
        node_class: NodeClass = .unknown,
        hw_model: String? = nil,
        role: String? = nil,
        first_seen_at: Int64,
        last_heard_at: Int64
    ) {
        self.node_num = node_num
        self.hexid = hexid
        self.short_name = short_name
        self.long_name = long_name
        self.node_class = node_class
        self.hw_model = hw_model
        self.role = role
        self.first_seen_at = first_seen_at
        self.last_heard_at = last_heard_at
    }
}

/// `node_config` — per-node config snapshot. Secrets never stored here.
public struct NodeConfigRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = Table.nodeConfig
    public var node_num: Int64
    public var region: String?
    public var channels_json: String?
    public var position_precision: Int?
    public var mqtt_json: String?

    public init(
        node_num: Int64,
        region: String? = nil,
        channels_json: String? = nil,
        position_precision: Int? = nil,
        mqtt_json: String? = nil
    ) {
        self.node_num = node_num
        self.region = region
        self.channels_json = channels_json
        self.position_precision = position_precision
        self.mqtt_json = mqtt_json
    }
}

/// `observation` — append-only provenance, one row per (deduped) reception
/// (SPEC §2.4). Unique on `(packet_id, node_num)`.
public struct ObservationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = Table.observation
    public var id: Int64?
    public var node_num: Int64
    public var packet_id: Int64
    public var transport: Transport
    public var gateway_id: String?
    public var rx_time: Int64
    public var rx_rssi: Int?
    public var rx_snr: Double?
    public var hop_start: Int?
    public var hop_limit: Int?

    public init(
        id: Int64? = nil,
        node_num: Int64,
        packet_id: Int64,
        transport: Transport,
        gateway_id: String? = nil,
        rx_time: Int64,
        rx_rssi: Int? = nil,
        rx_snr: Double? = nil,
        hop_start: Int? = nil,
        hop_limit: Int? = nil
    ) {
        self.id = id
        self.node_num = node_num
        self.packet_id = packet_id
        self.transport = transport
        self.gateway_id = gateway_id
        self.rx_time = rx_time
        self.rx_rssi = rx_rssi
        self.rx_snr = rx_snr
        self.hop_start = hop_start
        self.hop_limit = hop_limit
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// `position_fix` — time-series of GPS fixes.
public struct PositionFixRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = Table.positionFix
    public var id: Int64?
    public var node_num: Int64
    public var t: Int64
    public var lat: Double
    public var lon: Double
    public var alt: Double?
    public var sats: Int?
    public var h_accuracy: Double?
    public var precision_bits: Int?

    public init(
        id: Int64? = nil,
        node_num: Int64,
        t: Int64,
        lat: Double,
        lon: Double,
        alt: Double? = nil,
        sats: Int? = nil,
        h_accuracy: Double? = nil,
        precision_bits: Int? = nil
    ) {
        self.id = id
        self.node_num = node_num
        self.t = t
        self.lat = lat
        self.lon = lon
        self.alt = alt
        self.sats = sats
        self.h_accuracy = h_accuracy
        self.precision_bits = precision_bits
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// `telemetry` — typed time-series. `kind` groups, `key` names, `value` carries.
public struct TelemetryRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = Table.telemetry
    public var id: Int64?
    public var node_num: Int64
    public var t: Int64
    public var kind: TelemetryKind
    public var key: String
    public var value: Double

    public init(
        id: Int64? = nil,
        node_num: Int64,
        t: Int64,
        kind: TelemetryKind,
        key: String,
        value: Double
    ) {
        self.id = id
        self.node_num = node_num
        self.t = t
        self.kind = kind
        self.key = key
        self.value = value
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// `arming` — one row per node; movement anchor + hysteresis state (SPEC §2.3).
public struct ArmingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = Table.arming
    public var node_num: Int64
    public var armed: Bool
    public var threshold_m: Double
    public var anchor_lat: Double?
    public var anchor_lon: Double?
    public var anchor_accuracy: Double?
    public var captured_at: Int64?
    public var state: ArmingState

    public init(
        node_num: Int64,
        armed: Bool,
        threshold_m: Double,
        anchor_lat: Double? = nil,
        anchor_lon: Double? = nil,
        anchor_accuracy: Double? = nil,
        captured_at: Int64? = nil,
        state: ArmingState = .anchored
    ) {
        self.node_num = node_num
        self.armed = armed
        self.threshold_m = threshold_m
        self.anchor_lat = anchor_lat
        self.anchor_lon = anchor_lon
        self.anchor_accuracy = anchor_accuracy
        self.captured_at = captured_at
        self.state = state
    }
}

/// `alert_rule` — typed, data-driven rule with a config scope (SPEC §2.6).
public struct AlertRuleRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = Table.alertRule
    public var id: Int64?
    public var scope: String
    public var scope_id: String?
    public var type: String
    public var params_json: String?
    public var enabled: Bool

    public init(
        id: Int64? = nil,
        scope: String,
        scope_id: String? = nil,
        type: String,
        params_json: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.scope = scope
        self.scope_id = scope_id
        self.type = type
        self.params_json = params_json
        self.enabled = enabled
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// `alert` — a fired alert moving through the state machine (SPEC §2.6).
public struct AlertRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = Table.alert
    public var id: Int64?
    public var rule_id: Int64?
    public var node_num: Int64
    public var type: String
    public var state: AlertState
    public var fired_at: Int64
    public var acked_at: Int64?
    public var resolved_at: Int64?
    public var payload_json: String?

    public init(
        id: Int64? = nil,
        rule_id: Int64? = nil,
        node_num: Int64,
        type: String,
        state: AlertState = .firing,
        fired_at: Int64,
        acked_at: Int64? = nil,
        resolved_at: Int64? = nil,
        payload_json: String? = nil
    ) {
        self.id = id
        self.rule_id = rule_id
        self.node_num = node_num
        self.type = type
        self.state = state
        self.fired_at = fired_at
        self.acked_at = acked_at
        self.resolved_at = resolved_at
        self.payload_json = payload_json
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// `template` — reusable provisioning template (SPEC §2.7).
public struct TemplateRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = Table.template
    public var id: Int64?
    public var name: String
    public var dsl: String
    public var region: String
    public var role: String?
    public var config_json: String?
    public var firmware_variant: String?

    public init(
        id: Int64? = nil,
        name: String,
        dsl: String,
        region: String,
        role: String? = nil,
        config_json: String? = nil,
        firmware_variant: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dsl = dsl
        self.region = region
        self.role = role
        self.config_json = config_json
        self.firmware_variant = firmware_variant
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// swiftlint:enable identifier_name
