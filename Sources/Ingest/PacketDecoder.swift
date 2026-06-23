// PacketDecoder — raw ServiceEnvelope bytes → DecodedPacket (SPEC §2.5).
//
// This is the only place that bridges the generated protobufs into the Domain.
// For `/e/` (encrypted) packets it resolves the channel key from the KeyStore
// and decrypts via the PacketDecryptor port; plaintext `decoded` packets pass
// through. Decode is total: malformed input throws, it never crashes.

import Domain
import Foundation
import MeshProtos

/// Typed decode failures.
public enum PacketDecodeError: Error, Equatable, Sendable {
    case malformedEnvelope
    case malformedInnerData
}

public struct PacketDecoder: Sendable {
    private let keyStore: any KeyStore
    private let decryptor: any PacketDecryptor

    public init(keyStore: any KeyStore, decryptor: any PacketDecryptor) {
        self.keyStore = keyStore
        self.decryptor = decryptor
    }

    /// Decode one serialized `ServiceEnvelope`. Returns `nil` when the packet
    /// carries no usable payload or is encrypted with a channel key we don't
    /// hold (skip, not an error). Throws `PacketDecodeError` on malformed bytes.
    public func decode(serviceEnvelope bytes: [UInt8], receivedAt: Instant) throws -> DecodedPacket? {
        let envelope: ServiceEnvelope
        do {
            envelope = try ServiceEnvelope(serializedBytes: Data(bytes))
        } catch {
            throw PacketDecodeError.malformedEnvelope
        }
        guard envelope.hasPacket else { return nil }
        let packet = envelope.packet

        let data: DataMessage
        var wasEncrypted = false
        switch packet.payloadVariant {
        case let .decoded(plaintext):
            data = plaintext
        case let .encrypted(ciphertext):
            wasEncrypted = true
            guard let key = keyStore.key(forChannelHash: packet.channel) else { return nil }
            let plain = try decryptor.decrypt(
                [UInt8](ciphertext),
                packetID: packet.id,
                fromNode: packet.from,
                key: key
            )
            do {
                data = try DataMessage(serializedBytes: Data(plain))
            } catch {
                throw PacketDecodeError.malformedInnerData
            }
        case .none:
            return nil
        }

        return DecodedPacket(
            from: packet.from,
            to: packet.to,
            packetID: packet.id,
            channel: packet.channel,
            port: MeshPort(portNumRawValue: Int(data.portnum.rawValue)),
            payload: [UInt8](data.payload),
            // Our internal frame-receipt clock is the canonical packet time. The node's
            // firmware RTC is too often skewed to trust for ordering/placement, so we keep
            // it only as `nodeRxTime` for the descriptive receive→publish latency.
            rxTime: receivedAt,
            nodeRxTime: Self.nodeClaimedTime(packet),
            rxRssi: packet.rxRssi != 0 ? Int(packet.rxRssi) : nil,
            rxSnr: packet.rxSnr != 0 ? Double(packet.rxSnr) : nil,
            hopStart: packet.hopStart != 0 ? UInt8(truncatingIfNeeded: packet.hopStart) : nil,
            hopLimit: packet.hopLimit != 0 ? UInt8(truncatingIfNeeded: packet.hopLimit) : nil,
            relayNode: packet.relayNode != 0 ? UInt8(truncatingIfNeeded: packet.relayNode) : nil,
            nextHop: packet.nextHop != 0 ? UInt8(truncatingIfNeeded: packet.nextHop) : nil,
            gatewayID: Self.parseGatewayID(envelope.gatewayID),
            wasEncrypted: wasEncrypted
        )
    }

    /// Parse a `ServiceEnvelope.gateway_id` (`"!aabbccdd"`) into a node number.
    static func parseGatewayID(_ raw: String) -> UInt32? {
        guard raw.hasPrefix("!") else { return nil }
        return UInt32(raw.dropFirst(), radix: 16)
    }

    /// The node's *claimed* receive time, from the firmware-stamped `MeshPacket.rxTime`
    /// (whole seconds since 1970, the node's own RTC) — kept ONLY so the descriptive
    /// receive→publish latency (`ingest_time − nodeRxTime`, SPEC §2.11) stays real rather
    /// than ~0. A skewed node clock makes this wildly wrong, which is exactly why it no
    /// longer feeds `rxTime` (the canonical packet time). Omitted (sent as 0) → `nil`,
    /// and latency for that packet is simply unavailable.
    static func nodeClaimedTime(_ packet: MeshPacket) -> Instant? {
        guard packet.rxTime != 0 else { return nil }
        return Instant(nanosecondsSinceEpoch: Int64(packet.rxTime) * 1_000_000_000)
    }
}
