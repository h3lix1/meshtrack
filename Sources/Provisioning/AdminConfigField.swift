// AdminConfigField — the enum of every provisionable per-node field (SPEC §2.7).
//
// Each case's raw value is the snapshot key the templates/diff use; each has one
// `FieldSpec` entry in `registry` (see AdminConfigTable / AdminModuleConfigTable)
// describing its slot and string↔protobuf codec. Adding a field = adding a case
// here and a registry row — the apply/read-back/verify pipeline is generic over the
// registry and never changes.

import Foundation
import MeshProtos

/// A field Meshtrack knows how to provision over admin messages. Each case has one
/// entry in `registry` describing its slot and its string↔protobuf codec; the raw
/// value is the snapshot key the templates/diff use. Adding a field = adding a case
/// and a registry entry — nothing else in the pipeline changes.
public enum AdminConfigField: String, Sendable, CaseIterable {
    // MARK: Owner (User, via setOwner)

    /// Owner short name (≤ 4 bytes). Maps to `User.shortName`.
    case shortName = "short_name"
    /// Owner long name (≤ 39 bytes). Maps to `User.longName`.
    case longName = "long_name"

    // MARK: LoRa (Config.LoRaConfig)

    /// LoRa region (always set — legal, SPEC §2.9). Maps to `LoRaConfig.region`.
    case region
    /// Modem preset (LONG_FAST, MEDIUM_FAST, …). Maps to `LoRaConfig.modemPreset`.
    case modemPreset = "modem_preset"
    /// Whether to use a named modem preset vs explicit bandwidth/SF/CR.
    case usePreset = "use_preset"
    /// Mesh hop limit (0–7). Maps to `LoRaConfig.hopLimit`.
    case hopLimit = "hop_limit"
    /// Whether TX is enabled. Maps to `LoRaConfig.txEnabled`.
    case txEnabled = "tx_enabled"
    /// TX power in dBm. Maps to `LoRaConfig.txPower`.
    case txPower = "tx_power"
    /// LoRa channel number (frequency slot). Maps to `LoRaConfig.channelNum`.
    case loraChannelNum = "lora_channel_num"
    /// Override the region's duty-cycle limit. Maps to `LoRaConfig.overrideDutyCycle`.
    case overrideDutyCycle = "override_duty_cycle"
    /// Suppress all MQTT uplink/downlink for this node. Maps to `LoRaConfig.ignoreMqtt`.
    case loraIgnoreMqtt = "lora_ignore_mqtt"
    /// Whether the node consents to its config appearing on MQTT map reports.
    case configOkToMqtt = "config_ok_to_mqtt"

    // MARK: Device (Config.DeviceConfig)

    /// Device role. Maps to `DeviceConfig.role`.
    case role
    /// Rebroadcast mode (ALL / ALL_SKIP_DECODING / LOCAL_ONLY / …).
    case rebroadcastMode = "rebroadcast_mode"
    /// Node-info broadcast interval (seconds). Maps to `DeviceConfig.nodeInfoBroadcastSecs`.
    case nodeInfoBroadcastSecs = "node_info_broadcast_secs"
    /// Treat a double-tap as a button press. Maps to `DeviceConfig.doubleTapAsButtonPress`.
    case doubleTapAsButtonPress = "double_tap_as_button_press"
    /// POSIX timezone definition. Maps to `DeviceConfig.tzdef`.
    case tzdef
    /// Disable the LED heartbeat. Maps to `DeviceConfig.ledHeartbeatDisabled`.
    case ledHeartbeatDisabled = "led_heartbeat_disabled"

    // MARK: Position (Config.PositionConfig)

    /// Position broadcast interval (seconds). Maps to `PositionConfig.positionBroadcastSecs`.
    case positionBroadcastSecs = "position_broadcast_secs"
    /// Smart position broadcasting. Maps to `PositionConfig.positionBroadcastSmartEnabled`.
    case positionBroadcastSmartEnabled = "position_broadcast_smart_enabled"
    /// Pin the node to a fixed position. Maps to `PositionConfig.fixedPosition`.
    case fixedPosition = "fixed_position"
    /// GPS update interval (seconds). Maps to `PositionConfig.gpsUpdateInterval`.
    case gpsUpdateInterval = "gps_update_interval"
    /// GPS mode (DISABLED / ENABLED / NOT_PRESENT). Maps to `PositionConfig.gpsMode`.
    case gpsMode = "gps_mode"
    /// Position flags bitfield (what fields a position packet includes).
    case positionFlags = "position_flags"
    /// Position broadcast precision (bits). Maps to the PRIMARY channel's
    /// `ChannelSettings.ModuleSettings.positionPrecision` via `setChannel` —
    /// precision is a per-channel module setting, NOT a device-config bitfield.
    case positionPrecision = "position_precision"

    // MARK: Power (Config.PowerConfig)

    /// Force the device into power-saving mode. Maps to `PowerConfig.isPowerSaving`.
    case isPowerSaving = "is_power_saving"
    /// Shut down after this many seconds on battery. Maps to `PowerConfig.onBatteryShutdownAfterSecs`.
    case onBatteryShutdownAfterSecs = "on_battery_shutdown_after_secs"
    /// Seconds to wait for a Bluetooth connection before sleeping. `PowerConfig.waitBluetoothSecs`.
    case waitBluetoothSecs = "wait_bluetooth_secs"
    /// Super-deep-sleep duration (seconds). Maps to `PowerConfig.sdsSecs`.
    case sdsSecs = "sds_secs"
    /// Light-sleep duration (seconds). Maps to `PowerConfig.lsSecs`.
    case lsSecs = "ls_secs"
    /// Minimum wake duration (seconds). Maps to `PowerConfig.minWakeSecs`.
    case minWakeSecs = "min_wake_secs"

    // MARK: Network (Config.NetworkConfig)

    /// Enable WiFi. Maps to `NetworkConfig.wifiEnabled`.
    case wifiEnabled = "wifi_enabled"
    /// WiFi SSID. Maps to `NetworkConfig.wifiSsid`.
    case wifiSsid = "wifi_ssid"
    /// WiFi PSK. Maps to `NetworkConfig.wifiPsk`.
    case wifiPsk = "wifi_psk"
    /// NTP server hostname. Maps to `NetworkConfig.ntpServer`.
    case ntpServer = "ntp_server"
    /// Enable wired Ethernet. Maps to `NetworkConfig.ethEnabled`.
    case ethEnabled = "eth_enabled"

    // MARK: Display (Config.DisplayConfig)

    /// Screen-on timeout (seconds). Maps to `DisplayConfig.screenOnSecs`.
    case screenOnSecs = "screen_on_secs"
    /// Auto screen-carousel interval (seconds). Maps to `DisplayConfig.autoScreenCarouselSecs`.
    case autoScreenCarouselSecs = "auto_screen_carousel_secs"
    /// Keep compass north at the top. Maps to `DisplayConfig.compassNorthTop`.
    case compassNorthTop = "compass_north_top"
    /// Flip the screen 180°. Maps to `DisplayConfig.flipScreen`.
    case flipScreen = "flip_screen"
    /// Display units (METRIC / IMPERIAL). Maps to `DisplayConfig.units`.
    case displayUnits = "display_units"
    /// Wake the screen on tap or motion. Maps to `DisplayConfig.wakeOnTapOrMotion`.
    case wakeOnTapOrMotion = "wake_on_tap_or_motion"

    // MARK: Bluetooth (Config.BluetoothConfig)

    /// Enable Bluetooth. Maps to `BluetoothConfig.enabled`.
    case bluetoothEnabled = "bluetooth_enabled"
    /// Pairing mode (RANDOM_PIN / FIXED_PIN / NO_PIN). Maps to `BluetoothConfig.mode`.
    case bluetoothMode = "bluetooth_mode"
    /// Fixed pairing PIN (when mode is FIXED_PIN). Maps to `BluetoothConfig.fixedPin`.
    case bluetoothFixedPin = "bluetooth_fixed_pin"

    // MARK: Security (Config.SecurityConfig)

    /// Whether the node is managed (config locked to admin). Maps to `SecurityConfig.isManaged`.
    case securityIsManaged = "security_is_managed"
    /// Enable the serial console. Maps to `SecurityConfig.serialEnabled`.
    case securitySerialEnabled = "security_serial_enabled"
    /// Enable the debug-log API. Maps to `SecurityConfig.debugLogApiEnabled`.
    case debugLogApiEnabled = "debug_log_api_enabled"
    /// Enable the legacy admin channel. Maps to `SecurityConfig.adminChannelEnabled`.
    case adminChannelEnabled = "admin_channel_enabled"

    // MARK: MQTT module (ModuleConfig.MQTTConfig)

    /// Enable the MQTT module. Maps to `MQTTConfig.enabled`.
    case mqttEnabled = "mqtt_enabled"
    /// MQTT broker address. Maps to `MQTTConfig.address`.
    case mqttAddress = "mqtt_address"
    /// MQTT username. Maps to `MQTTConfig.username`.
    case mqttUsername = "mqtt_username"
    /// MQTT password. Maps to `MQTTConfig.password`.
    case mqttPassword = "mqtt_password"
    /// MQTT payload encryption. Maps to `MQTTConfig.encryptionEnabled`.
    case mqttEncryptionEnabled = "mqtt_encryption_enabled"
    /// MQTT JSON output. Maps to `MQTTConfig.jsonEnabled`.
    case mqttJsonEnabled = "mqtt_json_enabled"
    /// MQTT TLS. Maps to `MQTTConfig.tlsEnabled`.
    case mqttTlsEnabled = "mqtt_tls_enabled"
    /// MQTT topic root. Maps to `MQTTConfig.root`.
    case mqttRoot = "mqtt_root"
    /// Proxy MQTT through the phone client. Maps to `MQTTConfig.proxyToClientEnabled`.
    case mqttProxyToClientEnabled = "mqtt_proxy_to_client_enabled"
    /// Emit MQTT map reports. Maps to `MQTTConfig.mapReportingEnabled`.
    case mqttMapReportingEnabled = "mqtt_map_reporting_enabled"

    // MARK: Telemetry module (ModuleConfig.TelemetryConfig)

    /// Device telemetry update interval (seconds). Maps to `TelemetryConfig.deviceUpdateInterval`.
    case telemetryDeviceUpdateInterval = "telemetry_device_update_interval"
    /// Environment telemetry update interval (seconds). `TelemetryConfig.environmentUpdateInterval`.
    case telemetryEnvironmentUpdateInterval = "telemetry_environment_update_interval"
    /// Enable environment measurement. Maps to `TelemetryConfig.environmentMeasurementEnabled`.
    case telemetryEnvironmentMeasurementEnabled = "telemetry_environment_measurement_enabled"
    /// Show environment telemetry on screen. Maps to `TelemetryConfig.environmentScreenEnabled`.
    case telemetryEnvironmentScreenEnabled = "telemetry_environment_screen_enabled"
    /// Enable air-quality measurement. Maps to `TelemetryConfig.airQualityEnabled`.
    case telemetryAirQualityEnabled = "telemetry_air_quality_enabled"
    /// Enable power-metering measurement. Maps to `TelemetryConfig.powerMeasurementEnabled`.
    case telemetryPowerMeasurementEnabled = "telemetry_power_measurement_enabled"

    // MARK: NeighborInfo module (ModuleConfig.NeighborInfoConfig)

    /// Enable the neighbour-info module. Maps to `NeighborInfoConfig.enabled`.
    case neighborInfoEnabled = "neighbor_info_enabled"
    /// Neighbour-info update interval (seconds). Maps to `NeighborInfoConfig.updateInterval`.
    case neighborInfoUpdateInterval = "neighbor_info_update_interval"

    // MARK: StoreForward module (ModuleConfig.StoreForwardConfig)

    /// Enable store-and-forward. Maps to `StoreForwardConfig.enabled`.
    case storeForwardEnabled = "store_forward_enabled"
    /// Act as a store-and-forward server. Maps to `StoreForwardConfig.isServer`.
    case storeForwardIsServer = "store_forward_is_server"

    // MARK: Detection-sensor module (ModuleConfig.DetectionSensorConfig)

    /// Enable the detection-sensor module. Maps to `DetectionSensorConfig.enabled`.
    case detectionSensorEnabled = "detection_sensor_enabled"
    /// Detection-sensor monitor pin (GPIO). Maps to `DetectionSensorConfig.monitorPin`.
    case detectionSensorMonitorPin = "detection_sensor_monitor_pin"

    // MARK: Range-test module (ModuleConfig.RangeTestConfig)

    /// Enable the range-test module. Maps to `RangeTestConfig.enabled`.
    case rangeTestEnabled = "range_test_enabled"

    // MARK: Paxcounter module (ModuleConfig.PaxcounterConfig)

    /// Enable the paxcounter module. Maps to `PaxcounterConfig.enabled`.
    case paxcounterEnabled = "paxcounter_enabled"

    // MARK: - Registry lookup

    /// The registry entry describing this field's slot + codec. Every case has an
    /// entry (asserted by `every registry field is reachable from its raw key`); the
    /// `??` fallback is an inert owner stub that can never run because the lookup
    /// always hits — it only lets us avoid a force-unwrap (lint-banned).
    var spec: FieldSpec {
        AdminConfigField.specsByField[self] ?? .stub(self, slot: .owner) { _ in }
    }

    /// Every field's spec, keyed for O(1) lookup. Built once from `registry`.
    static let specsByField: [AdminConfigField: FieldSpec] =
        Dictionary(uniqueKeysWithValues: registry.map { ($0.field, $0) })

    /// Map a raw snapshot key back to a field (nil if unknown).
    static let specsByKey: [String: FieldSpec] =
        Dictionary(uniqueKeysWithValues: registry.map { ($0.field.rawValue, $0) })
}
