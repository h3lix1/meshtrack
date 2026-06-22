// AdminConfigVariants — seeds an empty `Config` / `ModuleConfig` payload variant
// for a given type (SPEC §2.7).
//
// When building a `setConfig` / `setModuleConfig` message, we start from the EMPTY
// sub-message of the touched type so each field's encoder can `extract` it, mutate
// one key-path, and `embed` it back. These helpers map a `ConfigType` /
// `ModuleConfigType` to its empty payload variant. The mapping is a build-once
// dictionary of factory closures (not a big switch) so it stays under the lint
// complexity cap and reads as a flat table. Pure; no I/O.

import Foundation
import MeshProtos

extension AdminMessageMapping {
    /// The empty `Config.OneOf_PayloadVariant` for `type`. Types Meshtrack doesn't
    /// provision fall through to a device config (defensive — the registry never
    /// asks for those).
    static func emptyConfigVariant(_ type: AdminMessage.ConfigType) -> Config.OneOf_PayloadVariant {
        emptyConfigVariants[type]?() ?? .device(Config.DeviceConfig())
    }

    /// The empty `ModuleConfig.OneOf_PayloadVariant` for `type`. Types Meshtrack
    /// doesn't provision fall through to an MQTT config (defensive).
    static func emptyModuleVariant(
        _ type: AdminMessage.ModuleConfigType
    ) -> ModuleConfig.OneOf_PayloadVariant {
        emptyModuleVariants[type]?() ?? .mqtt(ModuleConfig.MQTTConfig())
    }

    private static let emptyConfigVariants:
        [AdminMessage.ConfigType: @Sendable () -> Config.OneOf_PayloadVariant] = [
            .deviceConfig: { .device(Config.DeviceConfig()) },
            .positionConfig: { .position(Config.PositionConfig()) },
            .powerConfig: { .power(Config.PowerConfig()) },
            .networkConfig: { .network(Config.NetworkConfig()) },
            .displayConfig: { .display(Config.DisplayConfig()) },
            .loraConfig: { .lora(Config.LoRaConfig()) },
            .bluetoothConfig: { .bluetooth(Config.BluetoothConfig()) },
            .securityConfig: { .security(Config.SecurityConfig()) }
        ]

    private static let emptyModuleVariants:
        [AdminMessage.ModuleConfigType: @Sendable () -> ModuleConfig.OneOf_PayloadVariant] = [
            .mqttConfig: { .mqtt(ModuleConfig.MQTTConfig()) },
            .serialConfig: { .serial(ModuleConfig.SerialConfig()) },
            .extnotifConfig: { .externalNotification(ModuleConfig.ExternalNotificationConfig()) },
            .storeforwardConfig: { .storeForward(ModuleConfig.StoreForwardConfig()) },
            .rangetestConfig: { .rangeTest(ModuleConfig.RangeTestConfig()) },
            .telemetryConfig: { .telemetry(ModuleConfig.TelemetryConfig()) },
            .cannedmsgConfig: { .cannedMessage(ModuleConfig.CannedMessageConfig()) },
            .audioConfig: { .audio(ModuleConfig.AudioConfig()) },
            .remotehardwareConfig: { .remoteHardware(ModuleConfig.RemoteHardwareConfig()) },
            .neighborinfoConfig: { .neighborInfo(ModuleConfig.NeighborInfoConfig()) },
            .ambientlightingConfig: { .ambientLighting(ModuleConfig.AmbientLightingConfig()) },
            .detectionsensorConfig: { .detectionSensor(ModuleConfig.DetectionSensorConfig()) },
            .paxcounterConfig: { .paxcounter(ModuleConfig.PaxcounterConfig()) }
        ]
}
