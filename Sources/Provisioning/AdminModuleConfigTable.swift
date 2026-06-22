// AdminModuleConfigTable — the `ModuleConfig`-side rows of
// `AdminConfigField.registry` (SPEC §2.7). The `Config`-side rows live in
// `AdminConfigTable.swift`.
//
// One `FieldSpec` per provisionable module field, grouped by module sub-message.
// Each group declares a `ModuleLens` once, then one row per field. Append a row to
// widen the module surface — the apply/read-back/verify pipeline is generic over the
// registry. Pure data; no I/O.

import Foundation
import MeshProtos

extension AdminConfigField {
    /// Every provisionable module field, in a stable, grouped order.
    static let modules: [FieldSpec] = mqtt + telemetry + neighborInfo
        + storeForward + detectionSensor + rangeTest + paxcounter

    private static let mqtt: [FieldSpec] = {
        let lens = ModuleLens<ModuleConfig.MQTTConfig>(
            extract: { if case let .mqtt(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.mqtt = $0 },
            empty: { ModuleConfig.MQTTConfig() }
        )
        return [
            .moduleBool(.mqttEnabled, .mqttConfig, lens, \.enabled),
            .moduleString(.mqttAddress, .mqttConfig, lens, \.address),
            .moduleString(.mqttUsername, .mqttConfig, lens, \.username),
            .moduleString(.mqttPassword, .mqttConfig, lens, \.password),
            .moduleBool(.mqttEncryptionEnabled, .mqttConfig, lens, \.encryptionEnabled),
            .moduleBool(.mqttJsonEnabled, .mqttConfig, lens, \.jsonEnabled),
            .moduleBool(.mqttTlsEnabled, .mqttConfig, lens, \.tlsEnabled),
            .moduleString(.mqttRoot, .mqttConfig, lens, \.root),
            .moduleBool(.mqttProxyToClientEnabled, .mqttConfig, lens, \.proxyToClientEnabled),
            .moduleBool(.mqttMapReportingEnabled, .mqttConfig, lens, \.mapReportingEnabled)
        ]
    }()

    private static let telemetry: [FieldSpec] = {
        let lens = ModuleLens<ModuleConfig.TelemetryConfig>(
            extract: { if case let .telemetry(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.telemetry = $0 },
            empty: { ModuleConfig.TelemetryConfig() }
        )
        return [
            .moduleUInt32(.telemetryDeviceUpdateInterval, .telemetryConfig, lens, \.deviceUpdateInterval),
            .moduleUInt32(
                .telemetryEnvironmentUpdateInterval,
                .telemetryConfig,
                lens,
                \.environmentUpdateInterval
            ),
            .moduleBool(
                .telemetryEnvironmentMeasurementEnabled,
                .telemetryConfig,
                lens,
                \.environmentMeasurementEnabled
            ),
            .moduleBool(
                .telemetryEnvironmentScreenEnabled,
                .telemetryConfig,
                lens,
                \.environmentScreenEnabled
            ),
            .moduleBool(.telemetryAirQualityEnabled, .telemetryConfig, lens, \.airQualityEnabled),
            .moduleBool(.telemetryPowerMeasurementEnabled, .telemetryConfig, lens, \.powerMeasurementEnabled)
        ]
    }()

    private static let neighborInfo: [FieldSpec] = {
        let lens = ModuleLens<ModuleConfig.NeighborInfoConfig>(
            extract: { if case let .neighborInfo(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.neighborInfo = $0 },
            empty: { ModuleConfig.NeighborInfoConfig() }
        )
        return [
            .moduleBool(.neighborInfoEnabled, .neighborinfoConfig, lens, \.enabled),
            .moduleUInt32(.neighborInfoUpdateInterval, .neighborinfoConfig, lens, \.updateInterval)
        ]
    }()

    private static let storeForward: [FieldSpec] = {
        let lens = ModuleLens<ModuleConfig.StoreForwardConfig>(
            extract: { if case let .storeForward(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.storeForward = $0 },
            empty: { ModuleConfig.StoreForwardConfig() }
        )
        return [
            .moduleBool(.storeForwardEnabled, .storeforwardConfig, lens, \.enabled),
            .moduleBool(.storeForwardIsServer, .storeforwardConfig, lens, \.isServer)
        ]
    }()

    private static let detectionSensor: [FieldSpec] = {
        let lens = ModuleLens<ModuleConfig.DetectionSensorConfig>(
            extract: { if case let .detectionSensor(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.detectionSensor = $0 },
            empty: { ModuleConfig.DetectionSensorConfig() }
        )
        return [
            .moduleBool(.detectionSensorEnabled, .detectionsensorConfig, lens, \.enabled),
            .moduleUInt32(.detectionSensorMonitorPin, .detectionsensorConfig, lens, \.monitorPin)
        ]
    }()

    private static let rangeTest: [FieldSpec] = {
        let lens = ModuleLens<ModuleConfig.RangeTestConfig>(
            extract: { if case let .rangeTest(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.rangeTest = $0 },
            empty: { ModuleConfig.RangeTestConfig() }
        )
        return [.moduleBool(.rangeTestEnabled, .rangetestConfig, lens, \.enabled)]
    }()

    private static let paxcounter: [FieldSpec] = {
        let lens = ModuleLens<ModuleConfig.PaxcounterConfig>(
            extract: { if case let .paxcounter(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.paxcounter = $0 },
            empty: { ModuleConfig.PaxcounterConfig() }
        )
        return [.moduleBool(.paxcounterEnabled, .paxcounterConfig, lens, \.enabled)]
    }()
}
