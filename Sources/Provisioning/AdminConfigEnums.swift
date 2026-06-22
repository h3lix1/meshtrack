// AdminConfigEnums — the string ↔ firmware-enum codecs the registry's enum fields
// use (SPEC §2.7). Pure lookup tables; one `EnumCodec` per firmware enum we
// provision. Names are the canonical UPPER_SNAKE form (the same the diff/template
// model uses); parsing normalises case + separators first.

import Foundation
import MeshProtos

/// A two-way name↔code table for one firmware enum, with a safe fallback for an
/// unparseable value (validation rejects those upstream; the fallback only guards
/// the non-throwing encode path).
struct EnumCodec<E: RawRepresentable & Hashable & Sendable> where E.RawValue == Int {
    let byName: [String: E]
    let byCode: [E: String]
    /// The code used when a name doesn't parse (defensive — `validate` gates this).
    let fallback: E
    /// The name used when a code doesn't reverse-map.
    let fallbackName: String

    init(_ pairs: [(String, E)], fallback: E, fallbackName: String) {
        byName = Dictionary(uniqueKeysWithValues: pairs)
        byCode = Dictionary(uniqueKeysWithValues: pairs.map { ($1, $0) })
        self.fallback = fallback
        self.fallbackName = fallbackName
    }
}

/// Every firmware-enum codec the registry references. Built once.
enum EnumCodecs {
    static let region = EnumCodec<Config.LoRaConfig.RegionCode>(
        [
            ("UNSET", .unset), ("US", .us), ("EU_433", .eu433), ("EU_868", .eu868),
            ("CN", .cn), ("JP", .jp), ("ANZ", .anz), ("KR", .kr), ("TW", .tw),
            ("RU", .ru), ("IN", .in), ("NZ_865", .nz865), ("TH", .th),
            ("LORA_24", .lora24), ("UA_433", .ua433), ("UA_868", .ua868),
            ("MY_433", .my433), ("MY_919", .my919), ("SG_923", .sg923)
        ],
        fallback: .unset, fallbackName: "UNSET"
    )

    static let role = EnumCodec<Config.DeviceConfig.Role>(
        [
            ("CLIENT", .client), ("CLIENT_MUTE", .clientMute), ("ROUTER", .router),
            ("ROUTER_CLIENT", .routerClient), ("REPEATER", .repeater),
            ("TRACKER", .tracker), ("SENSOR", .sensor), ("TAK", .tak),
            ("CLIENT_HIDDEN", .clientHidden), ("LOST_AND_FOUND", .lostAndFound),
            ("TAK_TRACKER", .takTracker), ("ROUTER_LATE", .routerLate),
            ("CLIENT_BASE", .clientBase)
        ],
        fallback: .client, fallbackName: "CLIENT"
    )

    static let rebroadcastMode = EnumCodec<Config.DeviceConfig.RebroadcastMode>(
        [
            ("ALL", .all), ("ALL_SKIP_DECODING", .allSkipDecoding),
            ("LOCAL_ONLY", .localOnly), ("KNOWN_ONLY", .knownOnly),
            ("NONE", .none), ("CORE_PORTNUMS_ONLY", .corePortnumsOnly)
        ],
        fallback: .all, fallbackName: "ALL"
    )

    static let gpsMode = EnumCodec<Config.PositionConfig.GpsMode>(
        [("DISABLED", .disabled), ("ENABLED", .enabled), ("NOT_PRESENT", .notPresent)],
        fallback: .disabled, fallbackName: "DISABLED"
    )

    static let displayUnits = EnumCodec<Config.DisplayConfig.DisplayUnits>(
        [("METRIC", .metric), ("IMPERIAL", .imperial)],
        fallback: .metric, fallbackName: "METRIC"
    )

    static let modemPreset = EnumCodec<Config.LoRaConfig.ModemPreset>(
        [
            ("LONG_FAST", .longFast), ("LONG_SLOW", .longSlow),
            ("VERY_LONG_SLOW", .veryLongSlow), ("MEDIUM_SLOW", .mediumSlow),
            ("MEDIUM_FAST", .mediumFast), ("SHORT_SLOW", .shortSlow),
            ("SHORT_FAST", .shortFast), ("LONG_MODERATE", .longModerate),
            ("SHORT_TURBO", .shortTurbo)
        ],
        fallback: .longFast, fallbackName: "LONG_FAST"
    )

    static let bluetoothMode = EnumCodec<Config.BluetoothConfig.PairingMode>(
        [("RANDOM_PIN", .randomPin), ("FIXED_PIN", .fixedPin), ("NO_PIN", .noPin)],
        fallback: .randomPin, fallbackName: "RANDOM_PIN"
    )
}

// MARK: - Region / role string <-> enum (kept on the mapping for callers + tests)

extension AdminMessageMapping {
    /// Parse a region string (`"US"`, `"EU_868"`, …) to a firmware `RegionCode`,
    /// falling back to `.unset` for an unknown region (never a force-unwrap; the
    /// pre-apply `validate` is the place to reject bad input).
    static func regionCode(_ raw: String) -> Config.LoRaConfig.RegionCode {
        EnumCodecs.region.byName[normalize(raw)] ?? .unset
    }

    static func roleCode(_ raw: String) -> Config.DeviceConfig.Role {
        EnumCodecs.role.byName[normalize(raw)] ?? .client
    }

    static func regionString(_ code: Config.LoRaConfig.RegionCode) -> String {
        EnumCodecs.region.byCode[code] ?? "UNSET"
    }

    static func roleString(_ role: Config.DeviceConfig.Role) -> String {
        EnumCodecs.role.byCode[role] ?? "CLIENT"
    }

    /// Normalise a string for enum lookup: upper-case + dashes→underscores
    /// (`"eu-868"` → `"EU_868"`), so parsing is case- and separator-insensitive.
    static func normalize(_ raw: String) -> String {
        raw.uppercased().replacingOccurrences(of: "-", with: "_")
    }
}
