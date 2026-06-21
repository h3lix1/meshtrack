// DecodedPacket — the pure, decoded result of one MeshPacket (post-decrypt).
//
// The Ingest decoder maps MeshProtos (ServiceEnvelope/MeshPacket/DataMessage)
// into this Domain type, so the rest of Domain (rule engine, detectors) never
// imports protobuf. Provenance lives alongside the decoded app payload.

/// The Meshtastic application port a packet targets (a subset of `PortNum`,
/// modelled so Domain need not import the generated enum). Unmodelled ports keep
/// their raw number via `.other`.
public enum MeshPort: Sendable, Equatable {
    case textMessage
    case position
    case nodeInfo
    case routing
    case admin
    case waypoint
    case telemetry
    case mapReport
    case other(Int)

    public init(portNumRawValue raw: Int) {
        switch raw {
        case 1: self = .textMessage
        case 3: self = .position
        case 4: self = .nodeInfo
        case 5: self = .routing
        case 6: self = .admin
        case 8: self = .waypoint
        case 67: self = .telemetry
        case 73: self = .mapReport
        default: self = .other(raw)
        }
    }

    public var portNumRawValue: Int {
        switch self {
        case .textMessage: 1
        case .position: 3
        case .nodeInfo: 4
        case .routing: 5
        case .admin: 6
        case .waypoint: 8
        case .telemetry: 67
        case .mapReport: 73
        case let .other(raw): raw
        }
    }
}

/// A decoded packet: identity + provenance + the decoded application payload.
public struct DecodedPacket: Sendable, Equatable {
    public let from: UInt32
    public let to: UInt32
    public let packetID: UInt32
    /// The channel hash (`MeshPacket.channel`).
    public let channel: UInt32
    public let port: MeshPort
    /// The decoded (post-decrypt) application payload bytes.
    public let payload: [UInt8]
    /// When we received it (our clock / replay time), not the node's claimed time.
    public let rxTime: Instant
    public let rxRssi: Int?
    public let rxSnr: Double?
    public let hopStart: UInt8?
    public let hopLimit: UInt8?
    /// Whether the packet arrived encrypted (and was decrypted) vs. plaintext.
    public let wasEncrypted: Bool

    public init(
        from: UInt32,
        to: UInt32,
        packetID: UInt32,
        channel: UInt32,
        port: MeshPort,
        payload: [UInt8],
        rxTime: Instant,
        rxRssi: Int? = nil,
        rxSnr: Double? = nil,
        hopStart: UInt8? = nil,
        hopLimit: UInt8? = nil,
        wasEncrypted: Bool = false
    ) {
        self.from = from
        self.to = to
        self.packetID = packetID
        self.channel = channel
        self.port = port
        self.payload = payload
        self.rxTime = rxTime
        self.rxRssi = rxRssi
        self.rxSnr = rxSnr
        self.hopStart = hopStart
        self.hopLimit = hopLimit
        self.wasEncrypted = wasEncrypted
    }

    /// The dedup identity of this packet (SPEC §2.4).
    public var dedupKey: DedupKey {
        DedupKey(packetID: packetID, fromNode: from)
    }
}
