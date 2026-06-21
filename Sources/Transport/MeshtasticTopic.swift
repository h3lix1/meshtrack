// Meshtastic MQTT topic parsing (SPEC §2.5).
//
// Topics look like `msh/<REGION…>/2/<e|json|stat>/<CHANNEL>/<!gatewayid>`, where
// the region segment can have variable depth (e.g. `US`, `US/bayarea`). We anchor
// on the `2` protocol-version segment, then read the kind, channel, and gateway
// id after it. Pure — no I/O — so it's fully unit-tested.

/// A parsed Meshtastic MQTT topic.
public struct MeshtasticTopic: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// `/e/` — an encrypted (or PKI) ServiceEnvelope. The one we ingest.
        case encrypted = "e"
        /// `/json/` — convenience JSON, may be disabled; do not depend on it (SPEC §2.5).
        case json
        /// `/stat/` or anything else.
        case other
    }

    /// Region path joined with `/` (e.g. `US` or `US/bayarea`).
    public let region: String
    public let kind: Kind
    public let channel: String?
    /// The relaying gateway's `!hexid` (the topic USERID), if present.
    public let gatewayID: String?

    public init(region: String, kind: Kind, channel: String?, gatewayID: String?) {
        self.region = region
        self.kind = kind
        self.channel = channel
        self.gatewayID = gatewayID
    }

    /// Parse a topic, or `nil` if it is not a Meshtastic v2 topic.
    public static func parse(_ topic: String) -> MeshtasticTopic? {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "msh", let versionIndex = parts.firstIndex(of: "2"),
              versionIndex >= 1, versionIndex + 1 < parts.count else { return nil }

        let region = parts[1 ..< versionIndex].joined(separator: "/")
        let kind = Kind(rawValue: parts[versionIndex + 1]) ?? .other
        let channel = parts.count > versionIndex + 2 ? parts[versionIndex + 2] : nil
        let gatewayID = parts.count > versionIndex + 3 ? parts[versionIndex + 3] : nil
        return MeshtasticTopic(region: region, kind: kind, channel: channel, gatewayID: gatewayID)
    }
}
