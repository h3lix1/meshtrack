// Template model (SPEC §2.7). A reusable provisioning template: region (always
// set — legal), role, channels (PSKs live in Keychain, never here), position
// config, naming DSL, and an optional firmware variant. Pure; rendering validates
// the byte limits before anything is applied.

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

    public init(
        name: String,
        region: String,
        role: String? = nil,
        shortNameDSL: String? = nil,
        longNameDSL: String? = nil,
        channels: [String] = [],
        positionPrecisionBits: Int? = nil,
        firmwareVariant: String? = nil
    ) {
        self.name = name
        self.region = region
        self.role = role
        self.shortNameDSL = shortNameDSL
        self.longNameDSL = longNameDSL
        self.channels = channels
        self.positionPrecisionBits = positionPrecisionBits
        self.firmwareVariant = firmwareVariant
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
    public func desiredConfig(for context: NamingContext) throws -> [String: String] {
        var config = ["region": region]
        if let role { config["role"] = role }
        let names = try renderNames(for: context)
        if let shortName = names.shortName { config["short_name"] = shortName }
        if let longName = names.longName { config["long_name"] = longName }
        if let positionPrecisionBits { config["position_precision"] = String(positionPrecisionBits) }
        return config
    }
}
