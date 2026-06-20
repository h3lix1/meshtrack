// MeshTransport port — the inbound seam for every packet source.
//
// Adapters implement this: MQTTAdapter, SerialAdapter, BLEAdapter (production)
// and ReplayAdapter (test/replay). The port speaks raw bytes + provenance so it
// stays free of decoding concerns and Foundation `Data`; decoding the
// ServiceEnvelope/MeshPacket is the pipeline's job, using MeshProtos.

import Domain

/// A single inbound frame observed on some transport.
///
/// `payload` is the raw on-the-wire bytes (a `ServiceEnvelope` for MQTT `/e/`
/// and `/json` topics, or a framed `MeshPacket` for serial/BLE). Provenance is
/// captured per observation (SPEC §2.4); telemetry/position are counted once
/// after dedup on `(packet_id, from_num)`.
public struct InboundFrame: Sendable, Equatable {
    public enum Transport: String, Sendable, Equatable, CaseIterable {
        case mqtt
        case serial
        case ble
        case replay
    }

    public let transport: Transport
    /// MQTT topic the frame arrived on, if any (e.g. `msh/REGION/2/e/CH/USER`).
    public let topic: String?
    /// Raw on-the-wire bytes. Not yet decoded.
    public let payload: [UInt8]
    /// When the frame was received, per the `Clock` port (replay uses rx_time).
    public let receivedAt: Instant
    /// Gateway / USERID that relayed the frame, if known.
    public let gatewayID: String?

    public init(
        transport: Transport,
        topic: String?,
        payload: [UInt8],
        receivedAt: Instant,
        gatewayID: String? = nil
    ) {
        self.transport = transport
        self.topic = topic
        self.payload = payload
        self.receivedAt = receivedAt
        self.gatewayID = gatewayID
    }
}

/// Port: a source of inbound frames. The adapter owns its own connection
/// lifecycle; the stream finishes when the transport closes.
public protocol MeshTransport: Sendable {
    func frames() -> AsyncStream<InboundFrame>
}
