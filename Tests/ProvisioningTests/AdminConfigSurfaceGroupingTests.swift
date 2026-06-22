// AdminConfigSurfaceGroupingTests — the grouping / read-back-planning / read-modify-
// write / validation half of the broad config surface (Phase 10). Split from
// `AdminConfigSurfaceTests` (the per-field round-trips) so each test struct stays
// within the lint type-body cap.

import MeshProtos
@testable import Provisioning
import Testing

@Suite("AdminConfig broad surface — grouping / planning / validation (Phase 10)")
struct AdminConfigSurfaceGroupingTests {
    // MARK: Grouping — one message per config-type / module-type touched

    @Test
    func `fields of the same config type fold into one setConfig message`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "region", from: nil, to: "US"),
            ConfigChange(field: "hop_limit", from: nil, to: "5"),
            ConfigChange(field: "tx_power", from: nil, to: "27")
        ])
        let configs = messages.filter { if case .setConfig = $0.payloadVariant { true } else { false } }
        // All three are LoRa fields → exactly one setConfig carrying all three.
        #expect(configs.count == 1)
        guard case let .lora(lora)? = configs.first?.setConfig.payloadVariant else {
            Issue.record("expected a LoRa config payload")
            return
        }
        #expect(lora.region == .us)
        #expect(lora.hopLimit == 5)
        #expect(lora.txPower == 27)
    }

    @Test
    func `module fields fold into one setModuleConfig per module type`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "mqtt_enabled", from: nil, to: "true"),
            ConfigChange(field: "mqtt_address", from: nil, to: "x"),
            ConfigChange(field: "telemetry_device_update_interval", from: nil, to: "60")
        ])
        let modules = messages.filter { if case .setModuleConfig = $0.payloadVariant { true } else { false } }
        // mqtt (2 fields) + telemetry (1 field) → two module messages.
        #expect(modules.count == 2)
    }

    @Test
    func `a mixed config + module + owner + channel change set is one transaction`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "region", from: nil, to: "US"),
            ConfigChange(field: "role", from: nil, to: "ROUTER"),
            ConfigChange(field: "short_name", from: nil, to: "BMSH"),
            ConfigChange(field: "mqtt_enabled", from: nil, to: "true"),
            ConfigChange(field: "position_precision", from: nil, to: "16")
        ])
        #expect(messages.first?.beginEditSettings == true)
        #expect(messages.last?.commitEditSettings == true)
        let owners = messages.filter { if case .setOwner = $0.payloadVariant { true } else { false } }
        let configs = messages.filter { if case .setConfig = $0.payloadVariant { true } else { false } }
        let modules = messages.filter { if case .setModuleConfig = $0.payloadVariant { true } else { false } }
        let channels = messages.filter { if case .setChannel = $0.payloadVariant { true } else { false } }
        #expect(owners.count == 1)
        #expect(configs.count == 2) // lora + device
        #expect(modules.count == 1) // mqtt
        #expect(channels.count == 1) // position precision
    }

    // MARK: Read-back planning

    @Test
    func `configTypes and moduleConfigTypes route the read-back requests`() throws {
        let changes = [
            ConfigChange(field: "region", from: nil, to: "US"),
            ConfigChange(field: "screen_on_secs", from: nil, to: "30"),
            ConfigChange(field: "mqtt_enabled", from: nil, to: "true"),
            ConfigChange(field: "telemetry_device_update_interval", from: nil, to: "60"),
            ConfigChange(field: "short_name", from: nil, to: "BMSH"),
            ConfigChange(field: "position_precision", from: nil, to: "16")
        ]
        #expect(try AdminMessageMapping.configTypes(for: changes) == [.loraConfig, .displayConfig])
        #expect(try AdminMessageMapping.moduleConfigTypes(for: changes) == [.mqttConfig, .telemetryConfig])
        #expect(AdminMessageMapping.touchesOwner(changes))
        #expect(AdminMessageMapping.touchesChannel(changes))
    }

    // MARK: Module read-modify-write preserves untouched fields

    @Test
    func `a module apply preserves the read-back module's other fields`() throws {
        // Seed an existing MQTT module with an address + encryption on; change only
        // `enabled`. setModuleConfig REPLACES, so the read-modify-write must carry the
        // other fields forward.
        var existing = ModuleConfig.MQTTConfig()
        existing.address = "mqtt.bayme.sh"
        existing.encryptionEnabled = true
        var current = ModuleConfig()
        current.mqtt = existing

        let messages = try AdminMessageMapping.messages(
            for: [ConfigChange(field: "mqtt_enabled", from: "false", to: "true")],
            currentModuleConfigs: [current]
        )
        let setModule = try #require(
            messages.first { if case .setModuleConfig = $0.payloadVariant { true } else { false } }?
                .setModuleConfig
        )
        guard case let .mqtt(mqtt) = setModule.payloadVariant else {
            Issue.record("expected an MQTT module payload")
            return
        }
        #expect(mqtt.enabled) // updated
        #expect(mqtt.address == "mqtt.bayme.sh") // preserved
        #expect(mqtt.encryptionEnabled) // preserved
    }

    // MARK: Validation (the confirm-time guard)

    @Test
    func `validate accepts the broad surface`() throws {
        try AdminMessageMapping.validate([
            ConfigChange(field: "region", from: nil, to: "US"),
            ConfigChange(field: "modem_preset", from: nil, to: "long-fast"),
            ConfigChange(field: "hop_limit", from: nil, to: "7"),
            ConfigChange(field: "mqtt_enabled", from: nil, to: "true"),
            ConfigChange(field: "gps_mode", from: nil, to: "ENABLED")
        ])
    }

    @Test
    func `validate rejects a bad enum value with unknownEnum`() throws {
        #expect(throws: AdminMappingError.unknownEnum(field: "gps_mode", value: "WARP")) {
            try AdminMessageMapping.validate([ConfigChange(field: "gps_mode", from: nil, to: "WARP")])
        }
    }

    @Test
    func `validate rejects a non-numeric integer field`() throws {
        #expect(throws: AdminMappingError.invalidNumber(field: "hop_limit", value: "lots")) {
            try AdminMessageMapping.validate([ConfigChange(field: "hop_limit", from: nil, to: "lots")])
        }
    }

    @Test
    func `validate rejects a non-boolean toggle field`() throws {
        #expect(throws: AdminMappingError.invalidBool(field: "mqtt_enabled", value: "maybe")) {
            try AdminMessageMapping.validate([ConfigChange(field: "mqtt_enabled", from: nil, to: "maybe")])
        }
    }
}
