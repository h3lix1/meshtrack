// AdminMessageMapping — the pure bridge between Meshtrack's string-keyed config
// model (`ConfigChange`, the `[String: String]` snapshots templates render and
// diff against) and the Meshtastic `AdminMessage` / `Config` / `User` protobufs
// (SPEC §2.7).
//
// This is the heart of the admin transport and it is deliberately PURE: no I/O,
// no actors, no radio. It does two things, both fully testable:
//
//   • encode([ConfigChange]) -> [AdminMessage]  — the change→AdminMessage mapping
//     an apply sends over the wire (one or more `setConfig` / `setOwner` /
//     reboot messages, wrapped in a begin/commit edit transaction).
//   • decode(config:owner:) -> [String: String] — flatten a node's read-back
//     `Config` + `User` responses into the same string snapshot the diff uses,
//     so verification compares like-for-like.
//
// The send/receive of these messages is the effect boundary (`AdminTransport`),
// validated on hardware (HIL); the construction here is not.

import Foundation
import MeshProtos

/// A field Meshtrack knows how to provision over admin messages, with the
/// firmware enum/string parsing that maps our `[String: String]` model to the
/// protobufs. Adding a field means adding a case here (and its codec) — nothing
/// else in the pipeline changes.
public enum AdminConfigField: String, Sendable, CaseIterable {
    /// LoRa region (always set — legal, SPEC §2.9). Maps to `Config.LoRaConfig.region`.
    case region
    /// Device role. Maps to `Config.DeviceConfig.role`.
    case role
    /// Owner short name (≤ 4 bytes). Maps to `User.shortName` via `setOwner`.
    case shortName = "short_name"
    /// Owner long name (≤ 39 bytes). Maps to `User.longName` via `setOwner`.
    case longName = "long_name"
    /// Position broadcast precision (bits). Maps to the primary channel's
    /// `ChannelSettings.ModuleSettings.positionPrecision` via `setChannel` —
    /// precision is a per-channel module setting, NOT a device-config bitfield.
    case positionPrecision = "position_precision"
}

/// A typed failure constructing or interpreting an admin message — surfaced
/// instead of force-unwrapping an unparseable region/role or a malformed value.
public enum AdminMappingError: Error, Equatable, Sendable {
    /// A change targeted a field the admin transport does not know how to apply.
    case unsupportedField(String)
    /// A region string did not match any firmware `RegionCode`.
    case unknownRegion(String)
    /// A role string did not match any firmware `DeviceConfig.Role`.
    case unknownRole(String)
    /// A numeric field (e.g. position precision) was not a valid integer.
    case invalidNumber(field: String, value: String)
}

public enum AdminMessageMapping {
    // MARK: Change → AdminMessage (the apply path)

    /// Build the admin messages that apply `changes` to a node, wrapped in a
    /// begin/commit edit transaction so the firmware defers its implicit save
    /// (and any reboot) until everything is staged.
    ///
    /// Order is stable and deterministic: begin → owner (if any) → config (one
    /// per config-type touched) → channel (position precision, if any) → commit.
    /// PSKs are out of scope here (they live in Keychain); the `setChannel` we
    /// emit for precision carries only the primary channel's module setting.
    public static func messages(for changes: [ConfigChange]) throws -> [AdminMessage] {
        guard !changes.isEmpty else { return [] }
        let parsed = try changes.map(parse)

        var body: [AdminMessage] = []
        if let owner = ownerMessage(for: parsed) { body.append(owner) }
        body.append(contentsOf: configMessages(for: parsed))
        if let channel = channelMessage(for: parsed) { body.append(channel) }

        // A bare begin/commit with no body would be a pointless round-trip.
        guard !body.isEmpty else { return [] }
        return [edit(begin: true)] + body + [edit(begin: false)]
    }

    // MARK: Config response → snapshot (the read-back / verify path)

    /// Flatten a node's read-back `Config`, `User` and (primary) `Channel` into the
    /// string snapshot the diff compares against. Only the fields Meshtrack
    /// provisions are reported; absent sub-configs contribute nothing (so a partial
    /// read-back never fabricates a "current" value).
    public static func snapshot(config: Config?, owner: User?, channel: Channel? = nil) -> [String: String] {
        var snapshot: [String: String] = [:]
        if let config {
            switch config.payloadVariant {
            case let .lora(lora):
                snapshot[AdminConfigField.region.rawValue] = regionString(lora.region)
            case let .device(device):
                snapshot[AdminConfigField.role.rawValue] = roleString(device.role)
            default:
                break
            }
        }
        if let owner {
            if !owner.shortName.isEmpty {
                snapshot[AdminConfigField.shortName.rawValue] = owner.shortName
            }
            if !owner.longName.isEmpty {
                snapshot[AdminConfigField.longName.rawValue] = owner.longName
            }
        }
        if let channel, channel.hasSettings, channel.settings.hasModuleSettings {
            snapshot[AdminConfigField.positionPrecision.rawValue] =
                String(channel.settings.moduleSettings.positionPrecision)
        }
        return snapshot
    }

    /// Which firmware config-types a set of changes touches — the `getConfig`
    /// requests a read-back must issue to verify (region → lora, role → device).
    /// Owner fields are read via `getOwnerRequest` and position precision via
    /// `getChannelRequest`; both are reported separately (see `touchesOwner` /
    /// `touchesChannel`), not as `getConfig` types.
    public static func configTypes(for changes: [ConfigChange]) throws -> Set<AdminMessage.ConfigType> {
        var types: Set<AdminMessage.ConfigType> = []
        for change in changes {
            switch try field(for: change.field) {
            case .region: types.insert(.loraConfig)
            case .role: types.insert(.deviceConfig)
            case .positionPrecision: break // per-channel, read via getChannelRequest
            case .shortName, .longName: break // owner, not a getConfig type
            }
        }
        return types
    }

    /// Whether the changes include any owner field (short/long name), i.e. whether
    /// a read-back must also issue a `getOwnerRequest`.
    public static func touchesOwner(_ changes: [ConfigChange]) -> Bool {
        changes.contains { field(forOptional: $0.field) == .shortName ||
            field(forOptional: $0.field) == .longName
        }
    }

    /// Whether the changes touch a per-channel setting (position precision), i.e.
    /// whether a read-back must also issue a `getChannelRequest` for the primary
    /// channel to verify.
    public static func touchesChannel(_ changes: [ConfigChange]) -> Bool {
        changes.contains { field(forOptional: $0.field) == .positionPrecision }
    }

    // MARK: - Internals

    private struct ParsedChange {
        let field: AdminConfigField
        let value: String
    }

    private static func parse(_ change: ConfigChange) throws -> ParsedChange {
        try ParsedChange(field: field(for: change.field), value: change.to)
    }

    private static func field(for raw: String) throws -> AdminConfigField {
        guard let field = AdminConfigField(rawValue: raw) else {
            throw AdminMappingError.unsupportedField(raw)
        }
        return field
    }

    private static func field(forOptional raw: String) -> AdminConfigField? {
        AdminConfigField(rawValue: raw)
    }

    /// The `setOwner` message for any short/long-name changes (nil if none).
    private static func ownerMessage(for changes: [ParsedChange]) -> AdminMessage? {
        let short = changes.first { $0.field == .shortName }?.value
        let long = changes.first { $0.field == .longName }?.value
        guard short != nil || long != nil else { return nil }
        var owner = User()
        if let short { owner.shortName = short }
        if let long { owner.longName = long }
        var message = AdminMessage()
        message.setOwner = owner
        return message
    }

    /// One `setConfig` message per config-type touched (lora / device), each
    /// carrying only the fields that changed. Position precision is per-channel
    /// (see `channelMessage`), not a device config.
    private static func configMessages(for changes: [ParsedChange]) -> [AdminMessage] {
        var messages: [AdminMessage] = []
        if let region = changes.first(where: { $0.field == .region }) {
            var lora = Config.LoRaConfig()
            lora.region = regionCode(region.value)
            messages.append(setConfig(.lora(lora)))
        }
        if let role = changes.first(where: { $0.field == .role }) {
            var device = Config.DeviceConfig()
            device.role = roleCode(role.value)
            messages.append(setConfig(.device(device)))
        }
        return messages
    }

    /// The index of the primary channel — where position precision is provisioned.
    private static let primaryChannelIndex: Int32 = 0

    /// The `setChannel` message carrying position precision as the primary
    /// channel's `ModuleSettings.positionPrecision` (nil if precision unchanged).
    /// This is the firmware field precision actually lives in — NOT the
    /// device-config `position.positionFlags` boolean bitfield.
    private static func channelMessage(for changes: [ParsedChange]) -> AdminMessage? {
        guard let precision = changes.first(where: { $0.field == .positionPrecision }) else {
            return nil
        }
        var moduleSettings = ModuleSettings()
        moduleSettings.positionPrecision = UInt32(precision.value) ?? 0
        var settings = ChannelSettings()
        settings.moduleSettings = moduleSettings
        var channel = Channel()
        channel.index = primaryChannelIndex
        channel.role = .primary
        channel.settings = settings
        var message = AdminMessage()
        message.setChannel = channel
        return message
    }

    private static func setConfig(_ variant: Config.OneOf_PayloadVariant) -> AdminMessage {
        var config = Config()
        config.payloadVariant = variant
        var message = AdminMessage()
        message.setConfig = config
        return message
    }

    private static func edit(begin: Bool) -> AdminMessage {
        var message = AdminMessage()
        if begin { message.beginEditSettings = true } else { message.commitEditSettings = true }
        return message
    }

    // MARK: Region / role string <-> enum

    /// Parse a region string (`"US"`, `"EU_868"`, …) to a firmware `RegionCode`,
    /// falling back to `.unset` for an unknown region (never a force-unwrap; the
    /// pre-apply validation in `validate` is the place to reject bad input).
    static func regionCode(_ raw: String) -> Config.LoRaConfig.RegionCode {
        regionByName[normalize(raw)] ?? .unset
    }

    static func roleCode(_ raw: String) -> Config.DeviceConfig.Role {
        roleByName[normalize(raw)] ?? .client
    }

    static func regionString(_ code: Config.LoRaConfig.RegionCode) -> String {
        nameByRegion[code] ?? "UNSET"
    }

    static func roleString(_ role: Config.DeviceConfig.Role) -> String {
        nameByRole[role] ?? "CLIENT"
    }

    /// Validate that every change is a supported, parseable field BEFORE any apply.
    /// Throws the first problem (unknown region/role, non-numeric precision); used
    /// by the adapter as the confirm-time guard so a bad template can't be sent.
    public static func validate(_ changes: [ConfigChange]) throws {
        for change in changes {
            let field = try field(for: change.field)
            switch field {
            case .region:
                guard Self.regionByName[normalize(change.to)] != nil else {
                    throw AdminMappingError.unknownRegion(change.to)
                }
            case .role:
                guard Self.roleByName[normalize(change.to)] != nil else {
                    throw AdminMappingError.unknownRole(change.to)
                }
            case .positionPrecision:
                guard UInt32(change.to) != nil else {
                    throw AdminMappingError.invalidNumber(field: change.field, value: change.to)
                }
            case .shortName, .longName:
                break // byte-limit validation already happened at render time
            }
        }
    }

    private static func normalize(_ raw: String) -> String {
        raw.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    private static let regionByName: [String: Config.LoRaConfig.RegionCode] = [
        "UNSET": .unset, "US": .us, "EU_433": .eu433, "EU_868": .eu868, "CN": .cn,
        "JP": .jp, "ANZ": .anz, "KR": .kr, "TW": .tw, "RU": .ru, "IN": .in,
        "NZ_865": .nz865, "TH": .th, "LORA_24": .lora24, "UA_433": .ua433,
        "UA_868": .ua868, "MY_433": .my433, "MY_919": .my919, "SG_923": .sg923
    ]

    private static let nameByRegion: [Config.LoRaConfig.RegionCode: String] =
        Dictionary(uniqueKeysWithValues: regionByName.map { ($1, $0) })

    private static let roleByName: [String: Config.DeviceConfig.Role] = [
        "CLIENT": .client, "CLIENT_MUTE": .clientMute, "ROUTER": .router,
        "ROUTER_CLIENT": .routerClient, "REPEATER": .repeater, "TRACKER": .tracker,
        "SENSOR": .sensor, "TAK": .tak, "CLIENT_HIDDEN": .clientHidden,
        "LOST_AND_FOUND": .lostAndFound, "TAK_TRACKER": .takTracker,
        "ROUTER_LATE": .routerLate, "CLIENT_BASE": .clientBase
    ]

    private static let nameByRole: [Config.DeviceConfig.Role: String] =
        Dictionary(uniqueKeysWithValues: roleByName.map { ($1, $0) })
}
