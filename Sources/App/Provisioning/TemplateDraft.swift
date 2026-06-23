// TemplateDraft — the provisioning UI's editable working copy of a `NodeTemplate`
// (SPEC §2.7). String-typed fields for direct SwiftUI binding; `template` renders
// the live `NodeTemplate` an apply uses. Region is always populated (legal — it
// must be set on every node, SPEC §2.9), so it defaults to "US" rather than empty.
//
// This is the single-node provisioning sibling of `FleetConfigViewModel.TemplateDraft`;
// kept distinct so the guided workflow owns its own editor model and exposes the
// `template` accessor the flow renders against.

import Foundation
import Provisioning

public struct TemplateDraft: Sendable, Equatable {
    public var name: String
    /// LoRa region — always required (legal, SPEC §2.9).
    public var region: String
    public var role: String
    public var shortNameDSL: String
    public var longNameDSL: String
    /// Comma-separated channel names (PSKs live in the local key store, never here).
    public var channels: String
    /// Position broadcast precision in bits; empty = leave unset.
    public var positionPrecision: String

    public init(
        name: String = "New node",
        region: String = "US",
        role: String = "CLIENT",
        shortNameDSL: String = "{shortName}",
        longNameDSL: String = "{longName}",
        channels: String = "",
        positionPrecision: String = ""
    ) {
        self.name = name
        self.region = region
        self.role = role
        self.shortNameDSL = shortNameDSL
        self.longNameDSL = longNameDSL
        self.channels = channels
        self.positionPrecision = positionPrecision
    }

    /// The `NodeTemplate` this draft describes (what the workflow renders + applies).
    public var template: NodeTemplate {
        NodeTemplate(
            name: name,
            region: region,
            role: role.isEmpty ? nil : role,
            shortNameDSL: shortNameDSL.isEmpty ? nil : shortNameDSL,
            longNameDSL: longNameDSL.isEmpty ? nil : longNameDSL,
            channels: channels
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            positionPrecisionBits: Int(positionPrecision),
            firmwareVariant: nil
        )
    }
}
