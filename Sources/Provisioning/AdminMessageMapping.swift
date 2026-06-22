// AdminMessageMapping — the pure bridge between Meshtrack's string-keyed config
// model (`ConfigChange`, the `[String: String]` snapshots templates render and
// diff against) and the Meshtastic `AdminMessage` / `Config` / `ModuleConfig` /
// `User` protobufs (SPEC §2.7).
//
// This is the heart of the admin transport and it is deliberately PURE: no I/O,
// no actors, no radio. It does three things, all fully testable:
//
//   • encode([ConfigChange]) -> [AdminMessage]  — the change→AdminMessage mapping
//     an apply sends over the wire (one or more `setConfig` / `setModuleConfig` /
//     `setOwner` / `setChannel` messages, wrapped in a begin/commit edit
//     transaction).
//   • decode(config:owner:module:channel:) -> [String: String] — flatten a node's
//     read-back `Config` + `ModuleConfig` + `User` + `Channel` responses into the
//     same string snapshot the diff uses, so verification compares like-for-like.
//   • command(NodeAdminCommand) -> AdminMessage — the imperative, non-config admin
//     commands (favorite / unfavorite / ignore / unignore a node) that target a
//     node-num rather than a config field.
//
// The send/receive of these messages is the effect boundary (`AdminTransport`),
// validated on hardware (HIL); the construction here is not.
//
// ── The field registry ──────────────────────────────────────────────────────
// Rather than 200 ad-hoc switch cases, every provisionable field is one entry in
// `AdminConfigField.registry`: its string key, the `ConfigSlot` it lives in (which
// `setConfig`/`setModuleConfig`/owner/channel message carries it and which
// get-request reads it back), an `encode` that mutates the slot's protobuf, and a
// `decode` that reads the value back out as a string. Adding the rest of the proto
// surface is purely additive — append a registry entry; the apply/read-back/verify
// pipeline is generic over the registry and never changes.

import Foundation
import MeshProtos

/// Where a provisionable field lives in the firmware config model — both the
/// `setX` message that carries it on apply and the `getX` request that reads it
/// back on verify. The pipeline groups one message per distinct slot touched.
public enum ConfigSlot: Hashable, Sendable {
    /// A field of a `Config` sub-message (device/position/power/network/display/
    /// lora/bluetooth/security). Carried by `setConfig`, read via `getConfigRequest`.
    case config(AdminMessage.ConfigType)
    /// A field of a `ModuleConfig` sub-message (mqtt/serial/telemetry/…). Carried
    /// by `setModuleConfig`, read via `getModuleConfigRequest`.
    case module(AdminMessage.ModuleConfigType)
    /// An owner (`User`) field — short/long name. Carried by `setOwner`, read via
    /// `getOwnerRequest`.
    case owner
    /// A per-channel module setting on the PRIMARY channel (position precision).
    /// Carried by `setChannel` (a read-modify-write REPLACE), read via
    /// `getChannelRequest`.
    case channel
}

/// A typed failure constructing or interpreting an admin message — surfaced
/// instead of force-unwrapping an unparseable enum or a malformed value.
public enum AdminMappingError: Error, Equatable, Sendable {
    /// A change targeted a field the admin transport does not know how to apply.
    case unsupportedField(String)
    /// A region string did not match any firmware `RegionCode`.
    case unknownRegion(String)
    /// A role string did not match any firmware `DeviceConfig.Role`.
    case unknownRole(String)
    /// An enum-valued field (e.g. modem preset, gps mode) did not parse.
    case unknownEnum(field: String, value: String)
    /// A numeric field (e.g. position precision) was not a valid integer.
    case invalidNumber(field: String, value: String)
    /// A boolean field was not "true"/"false" (or 1/0).
    case invalidBool(field: String, value: String)
}

public enum AdminMessageMapping {
    // MARK: Change → AdminMessage (the apply path)

    /// Build the admin messages that apply `changes` to a node, wrapped in a
    /// begin/commit edit transaction so the firmware defers its implicit save
    /// (and any reboot) until everything is staged.
    ///
    /// Order is stable and deterministic: begin → owner (if any) → config (one
    /// per config-type touched, sorted) → module config (one per module-type
    /// touched, sorted) → channel (position precision, if any) → commit.
    ///
    /// `currentPrimaryChannel` is the node's existing primary `Channel`, read back
    /// before the apply. Position precision is a per-channel module setting, and the
    /// firmware treats `setChannel` as a REPLACE of the whole channel — so a
    /// precision change MUST be a read-modify-write that preserves the existing name,
    /// PSK, role and uplink/downlink flags. Pass the read-back channel here so the
    /// emitted `setChannel` carries those forward and only `positionPrecision` moves.
    /// When `nil` (no precision change, or no channel could be read) the channel is
    /// built fresh — acceptable only because precision is the sole channel field we
    /// touch and a missing read-back means there is nothing to preserve.
    public static func messages(
        for changes: [ConfigChange],
        currentPrimaryChannel: Channel? = nil,
        currentModuleConfigs: [ModuleConfig] = []
    ) throws -> [AdminMessage] {
        guard !changes.isEmpty else { return [] }
        let parsed = try changes.map(parse)

        var body: [AdminMessage] = []
        if let owner = try ownerMessage(for: parsed) { body.append(owner) }
        try body.append(contentsOf: configMessages(for: parsed))
        try body.append(contentsOf: moduleConfigMessages(for: parsed, current: currentModuleConfigs))
        if let channel = try channelMessage(for: parsed, current: currentPrimaryChannel) {
            body.append(channel)
        }

        // A bare begin/commit with no body would be a pointless round-trip.
        guard !body.isEmpty else { return [] }
        return [edit(begin: true)] + body + [edit(begin: false)]
    }

    // MARK: Command → AdminMessage (the imperative, non-config path)

    /// Build the single admin message for an imperative node command (favorite /
    /// unfavorite / ignore / unignore). These are NOT config diffs — they target a
    /// node-num directly and are not wrapped in a begin/commit transaction (the
    /// firmware applies them immediately). See `NodeAdminCommand`.
    public static func message(for command: NodeAdminCommand) -> AdminMessage {
        var message = AdminMessage()
        switch command {
        case let .favorite(nodeNum): message.setFavoriteNode = nodeNum
        case let .unfavorite(nodeNum): message.removeFavoriteNode = nodeNum
        case let .ignore(nodeNum): message.setIgnoredNode = nodeNum
        case let .unignore(nodeNum): message.removeIgnoredNode = nodeNum
        }
        return message
    }

    // MARK: Config response → snapshot (the read-back / verify path)

    /// Flatten a node's read-back `Config`, `ModuleConfig`, `User` and (primary)
    /// `Channel` into the string snapshot the diff compares against. Only the fields
    /// Meshtrack provisions are reported; absent sub-configs contribute nothing (so a
    /// partial read-back never fabricates a "current" value).
    public static func snapshot(
        config: Config? = nil,
        owner: User? = nil,
        module: ModuleConfig? = nil,
        channel: Channel? = nil
    ) -> [String: String] {
        var snapshot: [String: String] = [:]
        if let config { decodeConfig(config, into: &snapshot) }
        if let module { decodeModule(module, into: &snapshot) }
        if let owner { decodeOwner(owner, into: &snapshot) }
        if let channel { decodeChannel(channel, into: &snapshot) }
        return snapshot
    }

    // MARK: Read-back planning (which get-requests a verify must issue)

    /// Which firmware `Config`-types a set of changes touches — the `getConfigRequest`
    /// requests a read-back must issue to verify (region → lora, role → device, …).
    public static func configTypes(for changes: [ConfigChange]) throws -> Set<AdminMessage.ConfigType> {
        var types: Set<AdminMessage.ConfigType> = []
        for change in changes {
            if case let .config(type) = try field(for: change.field).spec.slot { types.insert(type) }
        }
        return types
    }

    /// Which firmware `ModuleConfig`-types a set of changes touches — the
    /// `getModuleConfigRequest` requests a read-back must issue to verify.
    public static func moduleConfigTypes(
        for changes: [ConfigChange]
    ) throws -> Set<AdminMessage.ModuleConfigType> {
        var types: Set<AdminMessage.ModuleConfigType> = []
        for change in changes {
            if case let .module(type) = try field(for: change.field).spec.slot { types.insert(type) }
        }
        return types
    }

    /// Whether the changes include any owner field (short/long name), i.e. whether
    /// a read-back must also issue a `getOwnerRequest`.
    public static func touchesOwner(_ changes: [ConfigChange]) -> Bool {
        changes.contains { slot(forOptional: $0.field) == .owner }
    }

    /// Whether the changes touch a per-channel setting (position precision), i.e.
    /// whether a read-back must also issue a `getChannelRequest` for the primary
    /// channel to verify.
    public static func touchesChannel(_ changes: [ConfigChange]) -> Bool {
        changes.contains { slot(forOptional: $0.field) == .channel }
    }

    // MARK: validate (the confirm-time guard)

    /// Validate that every change is a supported, parseable field BEFORE any apply.
    /// Throws the first problem (unknown enum, non-numeric int, bad bool); used by
    /// the adapter as the confirm-time guard so a bad template can't be sent.
    public static func validate(_ changes: [ConfigChange]) throws {
        for change in changes {
            // Parsing a change through its codec is exactly the validation: a bad
            // value throws here, before any message is built or sent.
            _ = try parse(change)
        }
    }

    // MARK: - Internals

    private struct ParsedChange {
        let field: AdminConfigField
        let value: String
    }

    private static func parse(_ change: ConfigChange) throws -> ParsedChange {
        let field = try field(for: change.field)
        // Run the codec's value-parse as the validation step (throws on bad input).
        try field.spec.validate(change.to)
        return ParsedChange(field: field, value: change.to)
    }

    private static func field(for raw: String) throws -> AdminConfigField {
        guard let field = AdminConfigField(rawValue: raw) else {
            throw AdminMappingError.unsupportedField(raw)
        }
        return field
    }

    private static func slot(forOptional raw: String) -> ConfigSlot? {
        AdminConfigField(rawValue: raw)?.spec.slot
    }

    // MARK: setOwner

    /// The `setOwner` message for any owner-field changes (nil if none). All owner
    /// fields are folded into one `User`.
    private static func ownerMessage(for changes: [ParsedChange]) throws -> AdminMessage? {
        let ownerChanges = changes.filter { $0.field.spec.slot == .owner }
        guard !ownerChanges.isEmpty else { return nil }
        var owner = User()
        for change in ownerChanges {
            try change.field.spec.encodeOwner(change.value, &owner)
        }
        var message = AdminMessage()
        message.setOwner = owner
        return message
    }

    // MARK: setConfig (one per ConfigType touched)

    /// One `setConfig` message per `Config`-type touched, each carrying only the
    /// fields that changed for that type. Emitted in a stable, sorted order.
    private static func configMessages(for changes: [ParsedChange]) throws -> [AdminMessage] {
        var byType: [AdminMessage.ConfigType: [ParsedChange]] = [:]
        for change in changes {
            if case let .config(type) = change.field.spec.slot {
                byType[type, default: []].append(change)
            }
        }
        return try byType.sorted { $0.key.rawValue < $1.key.rawValue }.map { type, typeChanges in
            // Seed the right (empty) sub-message so encoders mutate it in place.
            var config = Config()
            config.payloadVariant = Self.emptyConfigVariant(type)
            for change in typeChanges {
                try change.field.spec.encodeConfig(change.value, &config)
            }
            var message = AdminMessage()
            message.setConfig = config
            return message
        }
    }

    // MARK: setModuleConfig (one per ModuleConfigType touched)

    /// One `setModuleConfig` message per `ModuleConfig`-type touched, each carrying
    /// only the fields that changed for that type. Emitted in a stable, sorted order.
    ///
    /// `setModuleConfig` REPLACES the whole module sub-message on the node (like
    /// `setChannel`), so this is a read-modify-write: it starts from the matching
    /// read-back module in `current` (preserving every field we don't touch) and
    /// overwrites only the changed fields. Without a read-back it falls back to an
    /// empty sub-message (nothing to preserve).
    private static func moduleConfigMessages(
        for changes: [ParsedChange],
        current: [ModuleConfig]
    ) throws -> [AdminMessage] {
        var byType: [AdminMessage.ModuleConfigType: [ParsedChange]] = [:]
        for change in changes {
            if case let .module(type) = change.field.spec.slot {
                byType[type, default: []].append(change)
            }
        }
        return try byType.sorted { $0.key.rawValue < $1.key.rawValue }.map { type, typeChanges in
            // Start from the read-back module of this type (read-modify-write) or, when
            // none was read, an empty sub-message of the right variant.
            var module = ModuleConfig()
            module.payloadVariant = current.first { moduleType(of: $0) == type }?.payloadVariant
                ?? Self.emptyModuleVariant(type)
            for change in typeChanges {
                try change.field.spec.encodeModule(change.value, &module)
            }
            var message = AdminMessage()
            message.setModuleConfig = module
            return message
        }
    }

    /// The `ModuleConfigType` matching a `ModuleConfig`'s payload variant (nil for
    /// variants Meshtrack doesn't provision). Derived from the registry — a module
    /// field whose `matchesModule` accepts `module` carries that module's type — so
    /// there is no hand-maintained 16-way switch to drift out of sync. Used to pair a
    /// read-back module with its type for the read-modify-write above.
    private static func moduleType(of module: ModuleConfig) -> AdminMessage.ModuleConfigType? {
        for spec in AdminConfigField.registry where spec.matchesModule(module) {
            if case let .module(type) = spec.slot { return type }
        }
        return nil
    }

    // MARK: setChannel (position precision, read-modify-write)

    /// The index of the primary channel — where position precision is provisioned.
    private static let primaryChannelIndex: Int32 = 0

    /// The `setChannel` message carrying any per-channel field (position precision)
    /// as a read-modify-write over the read-back `current` channel (nil if none).
    /// `setChannel` REPLACES the whole channel, so we start from `current` (name,
    /// PSK, role, uplink/downlink flags, every other module setting) and overwrite
    /// only the changed channel field(s).
    private static func channelMessage(
        for changes: [ParsedChange],
        current: Channel?
    ) throws -> AdminMessage? {
        let channelChanges = changes.filter { $0.field.spec.slot == .channel }
        guard !channelChanges.isEmpty else { return nil }
        var channel = current ?? freshPrimaryChannel()
        for change in channelChanges {
            try change.field.spec.encodeChannel(change.value, &channel)
        }
        // Pin the addressing even when the read-back omitted it (targets the primary).
        channel.index = primaryChannelIndex
        channel.role = .primary
        var message = AdminMessage()
        message.setChannel = channel
        return message
    }

    /// A bare primary `Channel` used only when no read-back is available.
    private static func freshPrimaryChannel() -> Channel {
        var channel = Channel()
        channel.index = primaryChannelIndex
        channel.role = .primary
        return channel
    }

    private static func edit(begin: Bool) -> AdminMessage {
        var message = AdminMessage()
        if begin { message.beginEditSettings = true } else { message.commitEditSettings = true }
        return message
    }

    // MARK: Decode dispatch (read-back)

    private static func decodeConfig(_ config: Config, into snapshot: inout [String: String]) {
        for spec in AdminConfigField.registry where spec.matchesConfig(config) {
            if let value = spec.decodeConfig(config) {
                snapshot[spec.field.rawValue] = value
            }
        }
    }

    private static func decodeModule(_ module: ModuleConfig, into snapshot: inout [String: String]) {
        for spec in AdminConfigField.registry where spec.matchesModule(module) {
            if let value = spec.decodeModule(module) {
                snapshot[spec.field.rawValue] = value
            }
        }
    }

    private static func decodeOwner(_ owner: User, into snapshot: inout [String: String]) {
        for spec in AdminConfigField.registry where spec.slot == .owner {
            if let value = spec.decodeOwner(owner) {
                snapshot[spec.field.rawValue] = value
            }
        }
    }

    private static func decodeChannel(_ channel: Channel, into snapshot: inout [String: String]) {
        guard channel.hasSettings, channel.settings.hasModuleSettings else { return }
        for spec in AdminConfigField.registry where spec.slot == .channel {
            if let value = spec.decodeChannel(channel) {
                snapshot[spec.field.rawValue] = value
            }
        }
    }
}
