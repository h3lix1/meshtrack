// NodeConfigForm — the broad per-node config surface, organised into the sections
// the detail views render (Device, LoRa, Position, Power, Display, Network,
// Bluetooth, Security, Modules).
//
// This is the UI-side counterpart of `AdminConfigField`: a flat, presentation-only
// description of every field an operator can edit — its snapshot key (matching
// `AdminConfigField.rawValue`), a human label, and a control kind (chip-choice,
// on/off, free-text/number). The bespoke chip/toggle controls in the detail views
// render these so the headless ImageRenderer snapshot stays faithful (memory: stock
// Toggle/Picker render badly headless).
//
// `NodeConfigFormState` holds the live edit values and emits only the fields the
// operator actually changed (`changedFields`) so an apply diffs a minimal set
// through `ConfigDiff` → `AdminMessageMapping`.

import Foundation
import Observation

/// How a config field is edited in the form (drives which bespoke control renders).
public enum NodeConfigControl: Sendable, Equatable {
    /// A one-of chip picker over `options` (enum-valued fields).
    case choice(options: [String])
    /// An on/off pill (boolean fields). Rendered/stored as "true"/"false".
    case toggle
    /// A free-text value (strings + numbers). `numeric` hints the keypad/validation.
    case text(numeric: Bool)
}

/// One editable field: its snapshot key (== `AdminConfigField.rawValue`), label, and
/// control kind. Presentation-only; the encode/decode lives in `AdminMessageMapping`.
public struct NodeConfigFieldSpec: Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    public let control: NodeConfigControl

    public var id: String {
        key
    }

    public init(_ key: String, _ label: String, _ control: NodeConfigControl) {
        self.key = key
        self.label = label
        self.control = control
    }
}

/// A titled group of fields (Device, LoRa, …) — one collapsible section in the UI.
public struct NodeConfigSection: Sendable, Equatable, Identifiable {
    public let title: String
    public let fields: [NodeConfigFieldSpec]

    public var id: String {
        title
    }

    public init(_ title: String, _ fields: [NodeConfigFieldSpec]) {
        self.title = title
        self.fields = fields
    }
}

/// The full per-node config surface the detail views expose. Keys match
/// `AdminConfigField.rawValue` so edits flow straight through the admin pipeline.
public enum NodeConfigForm {
    public static let regions = ["US", "EU_868", "EU_433", "ANZ", "CN", "JP", "IN", "KR"]
    public static let roles = [
        "CLIENT", "CLIENT_MUTE", "ROUTER", "ROUTER_CLIENT", "REPEATER", "TRACKER", "SENSOR"
    ]

    /// Every section, in display order. Region/Role lead their sections because they
    /// are the most-edited fields (and back the legacy `(region, role)` edit).
    public static let sections: [NodeConfigSection] = [
        NodeConfigSection("LoRa", [
            .init("region", "Region", .choice(options: regions)),
            .init("modem_preset", "Modem Preset", .choice(options: [
                "LONG_FAST", "LONG_SLOW", "MEDIUM_SLOW", "MEDIUM_FAST", "SHORT_SLOW", "SHORT_FAST"
            ])),
            .init("hop_limit", "Hop Limit", .text(numeric: true)),
            .init("tx_enabled", "TX Enabled", .toggle),
            .init("tx_power", "TX Power (dBm)", .text(numeric: true)),
            .init("lora_channel_num", "Channel #", .text(numeric: true)),
            .init("override_duty_cycle", "Override Duty Cycle", .toggle),
            .init("config_ok_to_mqtt", "OK to MQTT", .toggle)
        ]),
        NodeConfigSection("Device", [
            .init("role", "Role", .choice(options: roles)),
            .init("rebroadcast_mode", "Rebroadcast", .choice(options: [
                "ALL", "ALL_SKIP_DECODING", "LOCAL_ONLY", "KNOWN_ONLY", "NONE"
            ])),
            .init("node_info_broadcast_secs", "NodeInfo Interval (s)", .text(numeric: true)),
            .init("double_tap_as_button_press", "Double-tap = Button", .toggle),
            .init("led_heartbeat_disabled", "Disable LED Heartbeat", .toggle)
        ]),
        NodeConfigSection("Position", [
            .init("position_precision", "Precision (bits)", .text(numeric: true)),
            .init("position_broadcast_secs", "Broadcast Interval (s)", .text(numeric: true)),
            .init("position_broadcast_smart_enabled", "Smart Broadcast", .toggle),
            .init("fixed_position", "Fixed Position", .toggle),
            .init("gps_mode", "GPS Mode", .choice(options: ["DISABLED", "ENABLED", "NOT_PRESENT"])),
            .init("gps_update_interval", "GPS Update (s)", .text(numeric: true))
        ]),
        NodeConfigSection("Power", [
            .init("is_power_saving", "Power Saving", .toggle),
            .init("on_battery_shutdown_after_secs", "Battery Shutdown (s)", .text(numeric: true)),
            .init("wait_bluetooth_secs", "Wait Bluetooth (s)", .text(numeric: true)),
            .init("min_wake_secs", "Min Wake (s)", .text(numeric: true))
        ]),
        NodeConfigSection("Display", [
            .init("screen_on_secs", "Screen On (s)", .text(numeric: true)),
            .init("display_units", "Units", .choice(options: ["METRIC", "IMPERIAL"])),
            .init("compass_north_top", "Compass North Top", .toggle),
            .init("flip_screen", "Flip Screen", .toggle),
            .init("wake_on_tap_or_motion", "Wake on Tap/Motion", .toggle)
        ]),
        NodeConfigSection("Network", [
            .init("wifi_enabled", "WiFi", .toggle),
            .init("wifi_ssid", "WiFi SSID", .text(numeric: false)),
            .init("eth_enabled", "Ethernet", .toggle),
            .init("ntp_server", "NTP Server", .text(numeric: false))
        ]),
        NodeConfigSection("Bluetooth", [
            .init("bluetooth_enabled", "Bluetooth", .toggle),
            .init("bluetooth_mode", "Pairing", .choice(options: ["RANDOM_PIN", "FIXED_PIN", "NO_PIN"])),
            .init("bluetooth_fixed_pin", "Fixed PIN", .text(numeric: true))
        ]),
        NodeConfigSection("Security", [
            .init("security_is_managed", "Managed (lock config)", .toggle),
            .init("security_serial_enabled", "Serial Console", .toggle),
            .init("debug_log_api_enabled", "Debug-log API", .toggle),
            .init("admin_channel_enabled", "Legacy Admin Channel", .toggle)
        ]),
        NodeConfigSection("Modules", [
            .init("mqtt_enabled", "MQTT", .toggle),
            .init("mqtt_address", "MQTT Address", .text(numeric: false)),
            .init("mqtt_encryption_enabled", "MQTT Encryption", .toggle),
            .init("telemetry_device_update_interval", "Telemetry Interval (s)", .text(numeric: true)),
            .init("telemetry_environment_measurement_enabled", "Environment Sensors", .toggle),
            .init("neighbor_info_enabled", "Neighbour Info", .toggle),
            .init("store_forward_enabled", "Store & Forward", .toggle),
            .init("detection_sensor_enabled", "Detection Sensor", .toggle),
            .init("range_test_enabled", "Range Test", .toggle)
        ])
    ]

    /// Every field across all sections (flat), for lookup / iteration.
    public static let allFields: [NodeConfigFieldSpec] = sections.flatMap(\.fields)
}

/// The live edit state for the broad config form: a value per field key, seeded from
/// the node's current snapshot. `changedFields` emits only what the operator moved
/// off the baseline, so an apply sends a minimal diff.
@Observable
@MainActor
public final class NodeConfigFormState {
    /// The current edit value per field key (== `AdminConfigField.rawValue`).
    public private(set) var values: [String: String]
    /// The baseline (node's current) value per field key — `changedFields` diffs
    /// against this.
    private let baseline: [String: String]

    public init(baseline: [String: String]) {
        self.baseline = baseline
        values = baseline
    }

    /// Seed the form for the TEMPLATE editor with the template's carried group
    /// defaults as BOTH the displayed values and the baseline, so `changedFields`
    /// surfaces exactly the edits the operator makes here. The caller folds those edits
    /// back into the draft (which may have been mutated by other means), so the form
    /// only ever overrides keys the operator actually touched in it — never clobbering a
    /// draft scalar set elsewhere.
    public init(templateFields: [String: String]) {
        baseline = templateFields
        values = templateFields
    }

    /// Read the current edit value for `key` (or the section spec's first choice /
    /// "false" default when unseeded, so a control always has something to show).
    public func value(for spec: NodeConfigFieldSpec) -> String {
        if let value = values[spec.key] { return value }
        switch spec.control {
        case let .choice(options): return options.first ?? ""
        case .toggle: return "false"
        case .text: return ""
        }
    }

    /// Set the edit value for `key`.
    public func set(_ value: String, for key: String) {
        values[key] = value
    }

    /// Toggle a boolean field (true⇄false).
    public func toggle(_ key: String) {
        values[key] = (values[key] == "true") ? "false" : "true"
    }

    /// The fields the operator actually changed off the baseline, keyed by snapshot
    /// key — the minimal set an apply diffs through the admin pipeline. Unseeded
    /// fields (no baseline, untouched) are skipped.
    public var changedFields: [String: String] {
        var changed: [String: String] = [:]
        for (key, value) in values where baseline[key] != value {
            changed[key] = value
        }
        return changed
    }
}
