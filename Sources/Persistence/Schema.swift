// Schema vocabulary: table names, the enums persisted as TEXT, and the typed
// error surface. Kept free of GRDB so the names can be referenced from tests and
// future query helpers without dragging in the driver.

import Domain

/// Canonical SQLite table names for schema v1 (SPEC §5).
///
/// Centralising the strings keeps record `databaseTableName`s, the migration,
/// and index creation in lock-step — a typo can only happen in one place.
public enum Table {
    public static let node = "node"
    public static let nodeConfig = "node_config"
    public static let observation = "observation"
    public static let positionFix = "position_fix"
    public static let telemetry = "telemetry"
    public static let telemetryHourly = "telemetry_hourly"
    public static let telemetryDaily = "telemetry_daily"
    public static let arming = "arming"
    public static let alertRule = "alert_rule"
    public static let alert = "alert"
    public static let template = "template"
    /// Monitor-only decoded text messages (schema v3, SPEC §1 amended / ADR 0006).
    public static let message = "message"
    /// Key-value store for non-secret app configuration (schema v4, Phase 8,
    /// SPEC §2.5/§10). Secrets never live here — they go to the Keychain.
    public static let appConfig = "app_config"
    /// Bounded sliding-window extraction-dedup ledger (schema v6, Phase 9,
    /// Finding 5). One last-seen row per packet identity, checked against the 600s
    /// window so dedup is durable across runs but does not drop legitimate later
    /// rows the way the v5 permanent unique indexes did (SPEC §2.4).
    public static let dedupSeen = "dedup_seen"
}

/// Node classification (SPEC §2.1) — the canonical type lives in Domain; persisted
/// as TEXT via its `rawValue`.
public typealias NodeClass = Domain.NodeClass

/// How an observation reached us (SPEC §2.4 provenance). Persisted as TEXT.
public enum Transport: String, Codable, Sendable, CaseIterable {
    /// Locally-attached node over USB serial.
    case serial
    /// Locally-attached node over Bluetooth Low Energy.
    case ble
    /// Public/region MQTT broker.
    case mqtt
    /// Deterministic replay of a captured corpus (test/CI ingestion).
    case replay
}

/// Telemetry family (SPEC §5 telemetry taxonomy). The concrete `key`
/// (e.g. `battery_pct`, `temp`) lives in its own column; `kind` groups them so a
/// query can pull "all device telemetry" without enumerating keys. Persisted as
/// TEXT.
public enum TelemetryKind: String, Codable, Sendable, CaseIterable {
    /// battery_pct, voltage, channel_util, air_util_tx, uptime.
    case device
    /// temp, humidity, pressure, lux.
    case environment
    /// per-channel current/voltage from a power-metering module.
    case power
}

/// Movement-detection state for an armed node (SPEC §2.3 hysteresis). Persisted
/// as TEXT.
public enum ArmingState: String, Codable, Sendable, CaseIterable {
    /// Armed, anchored, inside the threshold.
    case anchored
    /// Confirmed movement past the threshold.
    case moved
    /// Came back inside `threshold * return_ratio`.
    case returned
}

/// Lifecycle of a fired alert (SPEC §2.6 state machine) — canonical type in
/// Domain; persisted as TEXT via its `rawValue`.
public typealias AlertState = Domain.AlertState

/// Typed errors surfaced by the store. No `try!`/force-unwrap in production code;
/// callers get a precise, `Sendable` failure instead.
public enum StoreError: Error, Equatable, Sendable {
    /// A fetch keyed by `node_num` found no matching row.
    case nodeNotFound(nodeNum: Int64)
    /// A unique constraint (e.g. the observation dedup index) rejected a write.
    /// `details` carries the underlying SQLite message for diagnostics.
    case duplicate(details: String)
}
