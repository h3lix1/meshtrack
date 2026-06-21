// MeshMessage — the decoded result of one TEXT_MESSAGE_APP packet (monitor-only,
// ADR 0006). A pure Domain value type: the Ingest decoder maps a DecodedPacket's
// text payload into this, the Persistence layer maps it to a MessageRecord, and
// the Channels view renders it read-only. No send path.

/// The Meshtastic broadcast destination (`0xFFFFFFFF`): a message addressed to a
/// channel rather than to a specific node.
public let meshBroadcastAddress: UInt32 = 0xFFFF_FFFF

/// A decoded text message observed on the mesh.
public struct MeshMessage: Hashable, Sendable {
    public let packetID: UInt32
    public let from: UInt32
    public let to: UInt32
    /// The channel hash (`MeshPacket.channel`).
    public let channel: UInt32
    /// The human channel name, if known from config (else `nil`).
    public let channelName: String?
    /// The decoded UTF-8 message body.
    public let body: String
    /// When we received it (Clock / replay time).
    public let rxTime: Instant

    public init(
        packetID: UInt32,
        from: UInt32,
        to: UInt32,
        channel: UInt32,
        channelName: String? = nil,
        body: String,
        rxTime: Instant
    ) {
        self.packetID = packetID
        self.from = from
        self.to = to
        self.channel = channel
        self.channelName = channelName
        self.body = body
        self.rxTime = rxTime
    }
}

public extension MeshMessage {
    /// A direct message — addressed to a specific node, not the broadcast
    /// destination.
    var isDirectMessage: Bool {
        to != meshBroadcastAddress
    }

    /// `@short_name` style mentions found in the body (the leading `@` stripped),
    /// in order of appearance. A mention runs over word characters
    /// (alphanumeric + `_`) and ends at the first other character (whitespace,
    /// punctuation) or end-of-body. Used by the Channels view to highlight
    /// call-outs.
    var mentions: [String] {
        var found: [String] = []
        var pending: String?
        func flush() {
            if let name = pending, !name.isEmpty { found.append(name) }
            pending = nil
        }
        for scalar in body.unicodeScalars {
            if scalar == "@" {
                flush()
                pending = ""
            } else if pending != nil {
                if Self.isMentionCharacter(scalar) {
                    pending?.unicodeScalars.append(scalar)
                } else {
                    flush()
                }
            }
        }
        flush()
        return found
    }

    /// A character that may appear inside a mention: alphanumeric or `_`.
    private static func isMentionCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
            || ("0" ... "9").contains(scalar)
            || scalar == "_"
    }
}
