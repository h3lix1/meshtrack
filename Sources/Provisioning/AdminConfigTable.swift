// AdminConfigTable — the `Config`-side rows of `AdminConfigField.registry`
// (SPEC §2.7). The `ModuleConfig`-side rows live in `AdminModuleConfigTable.swift`.
//
// One `FieldSpec` per provisionable `Config` field, grouped by sub-message. Each
// group declares a `ConfigLens` once (extract / embed / fresh), then one row per
// field: field → key-path → scalar shape. This is the single place the config
// surface widens — append a row and the whole apply/read-back/verify pipeline picks
// it up. Pure data; no I/O.

import Foundation
import MeshProtos

extension AdminConfigField {
    /// Every provisionable field, in a stable, grouped order.
    static let registry: [FieldSpec] = owner + lora + device + position
        + power + network + display + bluetooth + security + modules

    // MARK: Owner (User, via setOwner)

    private static let owner: [FieldSpec] = [
        .ownerString(.shortName, \.shortName),
        .ownerString(.longName, \.longName)
    ]

    // MARK: LoRa (Config.LoRaConfig)

    private static let lora: [FieldSpec] = {
        let lens = ConfigLens<Config.LoRaConfig>(
            extract: { if case let .lora(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.lora = $0 },
            empty: { Config.LoRaConfig() }
        )
        return [
            .configEnum(
                .region,
                .loraConfig,
                lens,
                \.region,
                codec: EnumCodecs.region,
                error: { .unknownRegion($0) }
            ),
            .configEnum(.modemPreset, .loraConfig, lens, \.modemPreset, codec: EnumCodecs.modemPreset),
            .configBool(.usePreset, .loraConfig, lens, \.usePreset),
            .configUInt32(.hopLimit, .loraConfig, lens, \.hopLimit),
            .configBool(.txEnabled, .loraConfig, lens, \.txEnabled),
            .configInt32(.txPower, .loraConfig, lens, \.txPower),
            .configUInt32(.loraChannelNum, .loraConfig, lens, \.channelNum),
            .configBool(.overrideDutyCycle, .loraConfig, lens, \.overrideDutyCycle),
            .configBool(.loraIgnoreMqtt, .loraConfig, lens, \.ignoreMqtt),
            .configBool(.configOkToMqtt, .loraConfig, lens, \.configOkToMqtt)
        ]
    }()

    // MARK: Device (Config.DeviceConfig)

    private static let device: [FieldSpec] = {
        let lens = ConfigLens<Config.DeviceConfig>(
            extract: { if case let .device(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.device = $0 },
            empty: { Config.DeviceConfig() }
        )
        return [
            .configEnum(
                .role,
                .deviceConfig,
                lens,
                \.role,
                codec: EnumCodecs.role,
                error: { .unknownRole($0) }
            ),
            .configEnum(
                .rebroadcastMode,
                .deviceConfig,
                lens,
                \.rebroadcastMode,
                codec: EnumCodecs.rebroadcastMode
            ),
            .configUInt32(.nodeInfoBroadcastSecs, .deviceConfig, lens, \.nodeInfoBroadcastSecs),
            .configBool(.doubleTapAsButtonPress, .deviceConfig, lens, \.doubleTapAsButtonPress),
            .configString(.tzdef, .deviceConfig, lens, \.tzdef),
            .configBool(.ledHeartbeatDisabled, .deviceConfig, lens, \.ledHeartbeatDisabled)
        ]
    }()

    // MARK: Position (Config.PositionConfig) — precision is per-channel, see below

    private static let position: [FieldSpec] = {
        let lens = ConfigLens<Config.PositionConfig>(
            extract: { if case let .position(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.position = $0 },
            empty: { Config.PositionConfig() }
        )
        return [
            .configUInt32(.positionBroadcastSecs, .positionConfig, lens, \.positionBroadcastSecs),
            .configBool(
                .positionBroadcastSmartEnabled,
                .positionConfig,
                lens,
                \.positionBroadcastSmartEnabled
            ),
            .configBool(.fixedPosition, .positionConfig, lens, \.fixedPosition),
            .configUInt32(.gpsUpdateInterval, .positionConfig, lens, \.gpsUpdateInterval),
            .configEnum(.gpsMode, .positionConfig, lens, \.gpsMode, codec: EnumCodecs.gpsMode),
            .configUInt32(.positionFlags, .positionConfig, lens, \.positionFlags),
            // Position precision is a per-channel module setting carried by setChannel
            // as a read-modify-write, NOT a position-config field.
            positionPrecisionSpec
        ]
    }()

    // MARK: Power (Config.PowerConfig)

    private static let power: [FieldSpec] = {
        let lens = ConfigLens<Config.PowerConfig>(
            extract: { if case let .power(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.power = $0 },
            empty: { Config.PowerConfig() }
        )
        return [
            .configBool(.isPowerSaving, .powerConfig, lens, \.isPowerSaving),
            .configUInt32(.onBatteryShutdownAfterSecs, .powerConfig, lens, \.onBatteryShutdownAfterSecs),
            .configUInt32(.waitBluetoothSecs, .powerConfig, lens, \.waitBluetoothSecs),
            .configUInt32(.sdsSecs, .powerConfig, lens, \.sdsSecs),
            .configUInt32(.lsSecs, .powerConfig, lens, \.lsSecs),
            .configUInt32(.minWakeSecs, .powerConfig, lens, \.minWakeSecs)
        ]
    }()

    // MARK: Network (Config.NetworkConfig)

    private static let network: [FieldSpec] = {
        let lens = ConfigLens<Config.NetworkConfig>(
            extract: { if case let .network(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.network = $0 },
            empty: { Config.NetworkConfig() }
        )
        return [
            .configBool(.wifiEnabled, .networkConfig, lens, \.wifiEnabled),
            .configString(.wifiSsid, .networkConfig, lens, \.wifiSsid),
            .configString(.wifiPsk, .networkConfig, lens, \.wifiPsk),
            .configString(.ntpServer, .networkConfig, lens, \.ntpServer),
            .configBool(.ethEnabled, .networkConfig, lens, \.ethEnabled)
        ]
    }()

    // MARK: Display (Config.DisplayConfig)

    private static let display: [FieldSpec] = {
        let lens = ConfigLens<Config.DisplayConfig>(
            extract: { if case let .display(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.display = $0 },
            empty: { Config.DisplayConfig() }
        )
        return [
            .configUInt32(.screenOnSecs, .displayConfig, lens, \.screenOnSecs),
            .configUInt32(.autoScreenCarouselSecs, .displayConfig, lens, \.autoScreenCarouselSecs),
            .configBool(.compassNorthTop, .displayConfig, lens, \.compassNorthTop),
            .configBool(.flipScreen, .displayConfig, lens, \.flipScreen),
            .configEnum(.displayUnits, .displayConfig, lens, \.units, codec: EnumCodecs.displayUnits),
            .configBool(.wakeOnTapOrMotion, .displayConfig, lens, \.wakeOnTapOrMotion)
        ]
    }()

    // MARK: Bluetooth (Config.BluetoothConfig)

    private static let bluetooth: [FieldSpec] = {
        let lens = ConfigLens<Config.BluetoothConfig>(
            extract: { if case let .bluetooth(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.bluetooth = $0 },
            empty: { Config.BluetoothConfig() }
        )
        return [
            .configBool(.bluetoothEnabled, .bluetoothConfig, lens, \.enabled),
            .configEnum(.bluetoothMode, .bluetoothConfig, lens, \.mode, codec: EnumCodecs.bluetoothMode),
            .configUInt32(.bluetoothFixedPin, .bluetoothConfig, lens, \.fixedPin)
        ]
    }()

    // MARK: Security (Config.SecurityConfig)

    private static let security: [FieldSpec] = {
        let lens = ConfigLens<Config.SecurityConfig>(
            extract: { if case let .security(sub) = $0.payloadVariant { sub } else { nil } },
            embed: { $1.security = $0 },
            empty: { Config.SecurityConfig() }
        )
        return [
            .configBool(.securityIsManaged, .securityConfig, lens, \.isManaged),
            .configBool(.securitySerialEnabled, .securityConfig, lens, \.serialEnabled),
            .configBool(.debugLogApiEnabled, .securityConfig, lens, \.debugLogApiEnabled),
            .configBool(.adminChannelEnabled, .securityConfig, lens, \.adminChannelEnabled)
        ]
    }()

    // MARK: Channel (position precision, the one per-channel field)

    /// Position precision lives in the PRIMARY channel's `ModuleSettings`, not in
    /// `Config`. Encode is a read-modify-write that only touches the precision;
    /// decode reads it back off the channel's module settings.
    private static let positionPrecisionSpec: FieldSpec = {
        var spec = FieldSpec.stub(.positionPrecision, slot: .channel) {
            _ = try ValueParse.uint32($0, field: .positionPrecision)
        }
        spec.encodeChannel = { raw, channel in
            var settings = channel.hasSettings ? channel.settings : ChannelSettings()
            var module = settings.hasModuleSettings ? settings.moduleSettings : ModuleSettings()
            module.positionPrecision = try ValueParse.uint32(raw, field: .positionPrecision)
            settings.moduleSettings = module
            channel.settings = settings
        }
        spec.decodeChannel = { channel in
            guard channel.hasSettings, channel.settings.hasModuleSettings else { return nil }
            return String(channel.settings.moduleSettings.positionPrecision)
        }
        return spec
    }()
}
