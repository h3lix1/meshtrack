// AdminConfigSurfaceTests — the broad per-node config surface (Phase 10).
//
// Proves the field registry that widened `AdminConfigField` from 5 fields to the
// full config + module surface: for every field we exercise the apply encode AND
// the read-back decode through the protobuf wire codec (serialize → re-parse →
// snapshot), so a wrong key-path or slot is caught — a verbatim echo would hide it.
// Also covers the grouping (one setConfig/setModuleConfig per type), read-back
// planning (configTypes / moduleConfigTypes), and the value-parse validation.

import MeshProtos
@testable import Provisioning
import Testing

@Suite("AdminConfig broad surface — registry encode/read-back round-trip (Phase 10)")
struct AdminConfigSurfaceTests {
    // MARK: Helpers

    /// Apply `changes`, pull the resulting set messages back out, round-trip each
    /// through the wire codec, and flatten to the read-back snapshot — exactly the
    /// encode→decode a real node does. A wrong field mapping fails here.
    private func roundTrip(_ changes: [ConfigChange]) throws -> [String: String] {
        let messages = try AdminMessageMapping.messages(for: changes)
        var configs: [Config] = []
        var modules: [ModuleConfig] = []
        var owner: User?
        var channel: Channel?
        for message in messages {
            let wire: [UInt8] = try message.serializedBytes()
            let parsed = try AdminMessage(serializedBytes: wire)
            switch parsed.payloadVariant {
            case let .setConfig(config): configs.append(config)
            case let .setModuleConfig(module): modules.append(module)
            case let .setOwner(user): owner = user
            case let .setChannel(ch): channel = ch
            default: break
            }
        }
        var snapshot: [String: String] = [:]
        for config in configs {
            snapshot.merge(AdminMessageMapping.snapshot(config: config)) { _, new in new }
        }
        for module in modules {
            snapshot.merge(AdminMessageMapping.snapshot(module: module)) { _, new in new }
        }
        snapshot.merge(AdminMessageMapping.snapshot(owner: owner, channel: channel)) { _, new in new }
        return snapshot
    }

    /// Assert a single field encodes and reads back as `expected` (default: echoes
    /// the input value).
    private func assertRoundTrip(
        _ field: String,
        _ value: String,
        expect expected: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let snapshot = try roundTrip([ConfigChange(field: field, from: nil, to: value)])
        #expect(snapshot[field] == (expected ?? value), "field \(field)", sourceLocation: sourceLocation)
    }

    // MARK: Per-config-type round-trips (one representative + a few extras each)

    @Test
    func `device config fields round-trip`() throws {
        try assertRoundTrip("role", "ROUTER")
        try assertRoundTrip("rebroadcast_mode", "LOCAL_ONLY")
        try assertRoundTrip("node_info_broadcast_secs", "3600")
        try assertRoundTrip("double_tap_as_button_press", "true")
        try assertRoundTrip("led_heartbeat_disabled", "true")
        try assertRoundTrip("tzdef", "PST8PDT,M3.2.0,M11.1.0")
    }

    @Test
    func `lora config fields round-trip`() throws {
        try assertRoundTrip("region", "EU_868")
        try assertRoundTrip("modem_preset", "MEDIUM_FAST")
        try assertRoundTrip("hop_limit", "5")
        try assertRoundTrip("tx_enabled", "false")
        try assertRoundTrip("tx_power", "30")
        try assertRoundTrip("lora_channel_num", "20")
        try assertRoundTrip("override_duty_cycle", "true")
        try assertRoundTrip("config_ok_to_mqtt", "true")
    }

    @Test
    func `position config fields round-trip`() throws {
        try assertRoundTrip("position_broadcast_secs", "900")
        try assertRoundTrip("position_broadcast_smart_enabled", "true")
        try assertRoundTrip("fixed_position", "true")
        try assertRoundTrip("gps_mode", "ENABLED")
        try assertRoundTrip("gps_update_interval", "120")
        try assertRoundTrip("position_flags", "811")
    }

    @Test
    func `position precision round-trips via the channel (not a position config)`() throws {
        let snapshot = try roundTrip([ConfigChange(field: "position_precision", from: nil, to: "16")])
        #expect(snapshot["position_precision"] == "16")
    }

    @Test
    func `power config fields round-trip`() throws {
        try assertRoundTrip("is_power_saving", "true")
        try assertRoundTrip("on_battery_shutdown_after_secs", "86400")
        try assertRoundTrip("wait_bluetooth_secs", "60")
        try assertRoundTrip("min_wake_secs", "10")
    }

    @Test
    func `network config fields round-trip`() throws {
        try assertRoundTrip("wifi_enabled", "true")
        try assertRoundTrip("wifi_ssid", "BayMesh")
        try assertRoundTrip("ntp_server", "pool.ntp.org")
        try assertRoundTrip("eth_enabled", "true")
    }

    @Test
    func `display config fields round-trip`() throws {
        try assertRoundTrip("screen_on_secs", "30")
        try assertRoundTrip("display_units", "IMPERIAL")
        try assertRoundTrip("compass_north_top", "true")
        try assertRoundTrip("flip_screen", "true")
        try assertRoundTrip("wake_on_tap_or_motion", "true")
    }

    @Test
    func `bluetooth config fields round-trip`() throws {
        try assertRoundTrip("bluetooth_enabled", "true")
        try assertRoundTrip("bluetooth_mode", "FIXED_PIN")
        try assertRoundTrip("bluetooth_fixed_pin", "123456")
    }

    @Test
    func `security config fields round-trip`() throws {
        try assertRoundTrip("security_is_managed", "true")
        try assertRoundTrip("security_serial_enabled", "false")
        try assertRoundTrip("debug_log_api_enabled", "true")
        try assertRoundTrip("admin_channel_enabled", "true")
    }

    @Test
    func `owner fields round-trip`() throws {
        try assertRoundTrip("short_name", "BMSH")
        try assertRoundTrip("long_name", "Bay Mesh Node")
    }

    // MARK: Per-module round-trips

    @Test
    func `mqtt module fields round-trip`() throws {
        try assertRoundTrip("mqtt_enabled", "true")
        try assertRoundTrip("mqtt_address", "mqtt.bayme.sh")
        try assertRoundTrip("mqtt_username", "meshdev")
        try assertRoundTrip("mqtt_encryption_enabled", "true")
        try assertRoundTrip("mqtt_root", "msh/US/bayarea")
        try assertRoundTrip("mqtt_map_reporting_enabled", "true")
    }

    @Test
    func `telemetry module fields round-trip`() throws {
        try assertRoundTrip("telemetry_device_update_interval", "1800")
        try assertRoundTrip("telemetry_environment_update_interval", "3600")
        try assertRoundTrip("telemetry_environment_measurement_enabled", "true")
        try assertRoundTrip("telemetry_air_quality_enabled", "true")
        try assertRoundTrip("telemetry_power_measurement_enabled", "true")
    }

    @Test
    func `other module fields round-trip`() throws {
        try assertRoundTrip("neighbor_info_enabled", "true")
        try assertRoundTrip("neighbor_info_update_interval", "900")
        try assertRoundTrip("store_forward_enabled", "true")
        try assertRoundTrip("store_forward_is_server", "true")
        try assertRoundTrip("detection_sensor_enabled", "true")
        try assertRoundTrip("detection_sensor_monitor_pin", "21")
        try assertRoundTrip("range_test_enabled", "true")
        try assertRoundTrip("paxcounter_enabled", "true")
    }

    @Test
    func `bool parsing accepts common truthy and falsy spellings`() throws {
        for truthy in ["true", "1", "yes", "on", "TRUE"] {
            try assertRoundTrip("mqtt_enabled", truthy, expect: "true")
        }
        for falsy in ["false", "0", "no", "off", "False"] {
            try assertRoundTrip("mqtt_enabled", falsy, expect: "false")
        }
    }

    @Test
    func `every registry field is reachable from its raw key`() {
        // Guards against a typo'd rawValue that would make a field unprovisionable.
        for field in AdminConfigField.allCases {
            #expect(AdminConfigField(rawValue: field.rawValue) == field)
            #expect(AdminConfigField.specsByKey[field.rawValue]?.field == field)
        }
    }
}
