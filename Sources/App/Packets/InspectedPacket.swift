// InspectedPacket — a pure, byte-level breakdown + decoded field summary of one
// DecodedPacket (G6). The App library imports Domain only (not Ingest), so this is
// a self-contained reimplementation of the field/byte view over DecodedPacket —
// it never reaches for Ingest.PacketInspector.
//
// Everything here is pure and Sendable so the inspector view, the latency
// analytics, and the unit tests share one computation. SwiftUI lives elsewhere.

import Domain
import Foundation

/// A human-readable label for a `MeshPort`, kept here so Domain stays UI-free.
public enum PortLabel {
    public static func name(_ port: MeshPort) -> String {
        switch port {
        case .textMessage: "TEXT_MESSAGE"
        case .position: "POSITION"
        case .nodeInfo: "NODEINFO"
        case .routing: "ROUTING"
        case .admin: "ADMIN"
        case .waypoint: "WAYPOINT"
        case .telemetry: "TELEMETRY"
        case .mapReport: "MAP_REPORT"
        case let .other(raw): "PORT_\(raw)"
        }
    }
}

/// One row of a classic hex dump: the offset, the hex bytes, and the ASCII gutter.
public struct HexDumpRow: Identifiable, Sendable, Equatable {
    /// Byte offset of the first byte in this row.
    public let offset: Int
    /// Up to `bytesPerRow` bytes for this row.
    public let bytes: [UInt8]
    public let bytesPerRow: Int

    public var id: Int { offset }

    public init(offset: Int, bytes: [UInt8], bytesPerRow: Int) {
        self.offset = offset
        self.bytes = bytes
        self.bytesPerRow = bytesPerRow
    }

    /// `0000` style offset column.
    public var offsetText: String {
        String(format: "%04x", offset)
    }

    /// Space-separated two-digit hex, padded to a full row width so the ASCII
    /// gutter stays aligned on the final short row.
    public var hexText: String {
        let cells = bytes.map { String(format: "%02x", $0) }
        let padding = Array(repeating: "  ", count: max(0, bytesPerRow - bytes.count))
        return (cells + padding).joined(separator: " ")
    }

    /// Printable ASCII (`.` for non-printables) — the right-hand gutter.
    public var asciiText: String {
        String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}

/// A pure breakdown of one decoded packet: identity, provenance, decoded fields,
/// and the payload bytes rendered as a hex dump. This is the inspector's model.
public struct InspectedPacket: Identifiable, Sendable, Equatable {
    public let packet: DecodedPacket
    /// Our ingest clock at frame receipt, when known (drives latency). Nil for
    /// fixtures / pre-v3 rows where the ingest time was never stamped.
    public let ingestTime: Instant?
    /// Monotonic arrival sequence within the inspector window — a stable identity
    /// even when two packets share a packet id (relay duplicates).
    public let sequence: Int

    public var id: Int { sequence }

    public init(packet: DecodedPacket, ingestTime: Instant?, sequence: Int) {
        self.packet = packet
        self.ingestTime = ingestTime
        self.sequence = sequence
    }

    // MARK: Decoded field summary

    public var packetID: UInt32 { packet.packetID }
    public var from: UInt32 { packet.from }
    public var to: UInt32 { packet.to }
    public var channel: UInt32 { packet.channel }
    public var port: MeshPort { packet.port }
    public var portName: String { PortLabel.name(packet.port) }
    public var wasEncrypted: Bool { packet.wasEncrypted }

    /// Hops travelled = hopStart − hopLimit (clamped ≥ 0). Nil if either is absent.
    public var hops: Int? {
        guard let start = packet.hopStart, let limit = packet.hopLimit else { return nil }
        return max(0, Int(start) - Int(limit))
    }

    /// `!aabbccdd` formatting for a node id.
    public static func hexID(_ value: UInt32) -> String {
        String(format: "!%08x", value)
    }

    public var fromHex: String { Self.hexID(from) }
    public var toHex: String { Self.hexID(to) }

    /// `0x..` for the relay byte (last byte of the previous hop), or "—".
    public var relayByteText: String {
        packet.relayNode.map { String(format: "0x%02x", $0) } ?? "—"
    }

    public var gatewayText: String {
        packet.gatewayID.map(Self.hexID) ?? "—"
    }

    public var payloadByteCount: Int { packet.payload.count }

    // MARK: Byte-level hex breakdown

    /// The decoded payload as classic hex-dump rows (16 bytes per row by default).
    public func hexDump(bytesPerRow: Int = 16) -> [HexDumpRow] {
        let width = max(1, bytesPerRow)
        return stride(from: 0, to: packet.payload.count, by: width).map { start in
            let end = min(start + width, packet.payload.count)
            return HexDumpRow(
                offset: start,
                bytes: Array(packet.payload[start..<end]),
                bytesPerRow: width
            )
        }
    }

    // MARK: Latency (receive→publish)

    /// Receive→publish latency for this packet, when an ingest time is known.
    public var latency: ReceptionLatency? {
        ReceptionLatency.between(rxTime: packet.rxTime, ingestTime: ingestTime)
    }

    /// Latency in milliseconds (rounded), when known. Signed: a negative value
    /// means clock skew (the node's rx_time is ahead of our ingest clock).
    public var latencyMillis: Int? {
        latency.map { Int(($0.seconds * 1000).rounded()) }
    }

    /// A free-text haystack for the inspector's text filter: hex ids, port, payload.
    public var searchHaystack: String {
        var parts = [fromHex, toHex, portName, String(format: "!%08x", packetID)]
        if let gw = packet.gatewayID { parts.append(Self.hexID(gw)) }
        // include printable payload so text-message bodies are searchable
        let printable = String(packet.payload.compactMap { byte -> Character? in
            (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : nil
        })
        if !printable.isEmpty { parts.append(printable) }
        return parts.joined(separator: " ").lowercased()
    }
}
