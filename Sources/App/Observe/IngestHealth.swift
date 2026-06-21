// IngestHealth — the App-side mirror of the live ingestion pipeline's health
// (G10 observability). The `App` library must NOT import `Ingest`/`Transport`
// (snapshot-purity, phase7-gui §4), so we model a small value type here that the
// live coordinator (G2, in the MeshtrackApp executable) populates from the
// pipeline's `IngestSummary` plus per-transport connection state and clock
// timestamps. Everything in this file is pure and `Sendable`, so the derivations
// are unit-tested over hand-built snapshots — no MapKit, no I/O.

import Domain
import Foundation

/// Which transport a stream of frames arrived over. Mirrors the persistence
/// `Transport` enum's cases but lives in `App` so we never import the I/O ring.
public enum HealthTransport: String, Sendable, CaseIterable, Equatable, Identifiable {
    case mqtt
    case serial
    case ble

    public var id: String { rawValue }

    /// Human label for the dashboard.
    public var label: String {
        switch self {
        case .mqtt: "MQTT"
        case .serial: "Serial"
        case .ble: "BLE"
        }
    }
}

/// The health of one transport: whether it is connected, how many frames it has
/// carried, and when we last saw a packet on it.
public struct TransportHealth: Sendable, Equatable, Identifiable {
    public let transport: HealthTransport
    public let connected: Bool
    /// Frames received over this transport since the run began.
    public let framesReceived: Int
    /// When the last frame arrived on this transport (our ingest clock). `nil`
    /// when we have never seen one.
    public let lastFrameAt: Instant?

    public var id: String { transport.id }

    public init(
        transport: HealthTransport,
        connected: Bool,
        framesReceived: Int,
        lastFrameAt: Instant? = nil
    ) {
        self.transport = transport
        self.connected = connected
        self.framesReceived = framesReceived
        self.lastFrameAt = lastFrameAt
    }
}

/// A point-in-time snapshot of ingestion health. The live coordinator builds one
/// of these from the pipeline's running `IngestSummary` counters
/// (framesProcessed / packetsDecoded / decodeErrors / observationsRecorded /
/// duplicateDeliveriesSkipped / telemetryPointsRecorded / positionFixesRecorded /
/// messagesRecorded), the wall-clock at the last reception, and the per-transport
/// connection state. The dashboard derives every displayed metric from this value
/// (see `IngestHealthDashboard`), so the View is a pure function of the snapshot.
public struct IngestHealth: Sendable, Equatable {
    public var framesProcessed: Int
    public var packetsDecoded: Int
    public var decodeErrors: Int
    public var observationsRecorded: Int
    public var duplicateDeliveriesSkipped: Int
    public var telemetryPointsRecorded: Int
    public var positionFixesRecorded: Int
    public var messagesRecorded: Int
    /// Wall-clock (our ingest clock) of the most recent decoded packet. `nil`
    /// before the first packet arrives.
    public var lastPacketAt: Instant?
    /// When the live run started — used for uptime and average throughput.
    public var startedAt: Instant?
    /// Recent per-second throughput samples (oldest → newest), for the sparkline.
    public var throughputSamples: [Double]
    public var transports: [TransportHealth]

    public init(
        framesProcessed: Int = 0,
        packetsDecoded: Int = 0,
        decodeErrors: Int = 0,
        observationsRecorded: Int = 0,
        duplicateDeliveriesSkipped: Int = 0,
        telemetryPointsRecorded: Int = 0,
        positionFixesRecorded: Int = 0,
        messagesRecorded: Int = 0,
        lastPacketAt: Instant? = nil,
        startedAt: Instant? = nil,
        throughputSamples: [Double] = [],
        transports: [TransportHealth] = []
    ) {
        self.framesProcessed = framesProcessed
        self.packetsDecoded = packetsDecoded
        self.decodeErrors = decodeErrors
        self.observationsRecorded = observationsRecorded
        self.duplicateDeliveriesSkipped = duplicateDeliveriesSkipped
        self.telemetryPointsRecorded = telemetryPointsRecorded
        self.positionFixesRecorded = positionFixesRecorded
        self.messagesRecorded = messagesRecorded
        self.lastPacketAt = lastPacketAt
        self.startedAt = startedAt
        self.throughputSamples = throughputSamples
        self.transports = transports
    }
}
