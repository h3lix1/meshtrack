// LivePacketTraceCollector — folds the live decoded-packet stream into animated
// traces (SPEC §1). Each DecodedPacket becomes a per-gateway PacketReception;
// receptions are grouped by packet id over a sliding window (the most-recent N
// packets animate at once, oldest evicted). traces() reconstructs them via
// PacketTraceBuilder, staggering startedAt by arrival so they animate in sequence.
// Pure + tested; the view model feeds it from the ingest pipeline.

import Domain

public struct LivePacketTraceCollector: Sendable {
    private var receptionsByPacket: [UInt32: [PacketReception]] = [:]
    private var arrivalOrder: [UInt32] = []
    private let maxPackets: Int

    public init(maxPackets: Int = 12) {
        self.maxPackets = max(1, maxPackets)
    }

    public var packetCount: Int {
        arrivalOrder.count
    }

    /// Fold one decoded packet in as a gateway reception of its packet id.
    public mutating func ingest(_ packet: DecodedPacket) {
        let reception = PacketReception(
            packetID: packet.packetID,
            fromNode: Int64(packet.from),
            gatewayNode: packet.gatewayID.map { Int64($0) },
            relayNode: packet.relayNode ?? 0,
            hopStart: Int(packet.hopStart ?? 0),
            hopLimit: Int(packet.hopLimit ?? 0),
            rxTime: packet.rxTime
        )
        if receptionsByPacket[packet.packetID] == nil {
            arrivalOrder.append(packet.packetID)
        }
        receptionsByPacket[packet.packetID, default: []].append(reception)
        while arrivalOrder.count > maxPackets {
            receptionsByPacket[arrivalOrder.removeFirst()] = nil
        }
    }

    /// Reconstruct traces for the windowed packets, oldest first, `startedAt`
    /// staggered by arrival so the animation plays them in sequence.
    public func traces(positions: [Int64: GeoPoint], stagger: Double = 0.4) -> [PacketTrace] {
        arrivalOrder.enumerated().flatMap { index, packetID in
            PacketTraceBuilder.build(
                receptions: receptionsByPacket[packetID] ?? [],
                positions: positions,
                startedAt: Double(index) * stagger
            )
        }
    }
}
