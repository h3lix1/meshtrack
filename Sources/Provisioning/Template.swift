// Template model (SPEC §2.7). A reusable provisioning template: region (always
// set — legal), role, channels (PSKs live in the local key store, never here),
// position config, naming DSL, and an optional firmware variant. Pure; rendering
// validates the byte limits before anything is applied.

public struct RenderedNames: Sendable, Equatable {
    public let shortName: String?
    public let longName: String?
}

public struct NodeTemplate: Sendable, Equatable {
    public let name: String
    public let region: String
    public let role: String?
    public let shortNameDSL: String?
    public let longNameDSL: String?
    public let channels: [String]
    public let positionPrecisionBits: Int?
    public let firmwareVariant: String?
    /// The broad config surface, keyed by `AdminConfigField.rawValue` (SPEC §2.7).
    /// These are the group defaults a rollout applies on top of the named fields
    /// above — every LoRa / Device / Position / Power / Network / Display /
    /// Bluetooth / Security / module knob the per-node editor exposes. Defaulted
    /// empty so older call sites (and persisted records without `config_json`
    /// broad fields) keep working. A node's individual `NodeConfigEdit` overrides
    /// these defaults at apply time — see `desiredConfig(for:)`.
    public let fields: [String: String]

    public init(
        name: String,
        region: String,
        role: String? = nil,
        shortNameDSL: String? = nil,
        longNameDSL: String? = nil,
        channels: [String] = [],
        positionPrecisionBits: Int? = nil,
        firmwareVariant: String? = nil,
        fields: [String: String] = [:]
    ) {
        self.name = name
        self.region = region
        self.role = role
        self.shortNameDSL = shortNameDSL
        self.longNameDSL = longNameDSL
        self.channels = channels
        self.positionPrecisionBits = positionPrecisionBits
        self.firmwareVariant = firmwareVariant
        self.fields = fields
    }

    /// Render the node names, validating the Meshtastic byte limits (SPEC §2.1).
    public func renderNames(for context: NamingContext) throws -> RenderedNames {
        try RenderedNames(
            shortName: shortNameDSL.map { try NamingDSL.renderShortName($0, context: context) },
            longName: longNameDSL.map { try NamingDSL.renderLongName($0, context: context) }
        )
    }

    /// The desired config as field→value pairs, for diffing against the live node.
    /// Region is always present (legal requirement, SPEC §2.9).
    ///
    /// Merge order (later wins): the broad `fields` (group defaults) seed the config
    /// first; the named surface (region/role/rendered names/precision) overlays them,
    /// so a precision set both ways resolves to the typed `positionPrecisionBits`. The
    /// resulting dictionary is what `ConfigDiff` diffs against the live node and what a
    /// per-node `NodeConfigEdit` then overrides at apply time.
    public func desiredConfig(for context: NamingContext) throws -> [String: String] {
        var config = fields
        config["region"] = region
        if let role { config["role"] = role }
        let names = try renderNames(for: context)
        if let shortName = names.shortName { config["short_name"] = shortName }
        if let longName = names.longName { config["long_name"] = longName }
        if let positionPrecisionBits { config["position_precision"] = String(positionPrecisionBits) }
        return config
    }

    /// Reject a template that carries an unsupported broad-config key before it is
    /// saved or rolled out. The named surface (region/role/names/precision) is always
    /// valid; only the broad `fields` need checking against `AdminConfigField`. Mirrors
    /// the confirm-time guard `AdminMessageMapping.validate(...)` runs at apply, but
    /// fails the operator early — at edit/save — with the offending key.
    public func validate() throws {
        for key in fields.keys where AdminConfigField(rawValue: key) == nil {
            throw AdminMappingError.unsupportedField(key)
        }
    }
}
