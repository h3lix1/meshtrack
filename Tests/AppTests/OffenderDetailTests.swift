// OffenderDetailTests — the per-node why/how/when detail the offenders screen opens
// on tap. Proves the aggregator retains per-node detail (per-port emit/recv, gateway
// set, hop range, first/last seen, per-minute activity histogram) and that
// `TrafficAggregator.detail(forNode:)` shapes it correctly. Pure, no SwiftUI.

@testable import App
import Domain
import Testing

@Suite("OffenderDetail — per-node why/how/when derivation")
struct OffenderDetailTests {
    private func packet(
        from: UInt32 = 0xA1,
        packetID: UInt32,
        port: MeshPort = .position,
        gatewayID: UInt32? = 0xAA,
        at seconds: Double = 0,
        hopStart: UInt8? = 3,
        hopLimit: UInt8? = 1
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: 8, port: port,
            payload: [], rxTime: Instant.epoch.adding(seconds: seconds),
            hopStart: hopStart, hopLimit: hopLimit, gatewayID: gatewayID
        )
    }

    private func aggregator(_ packets: [DecodedPacket]) -> TrafficAggregator {
        var agg = TrafficAggregator()
        for packet in packets {
            agg.fold(packet)
        }
        return agg
    }

    @Test
    func `detail is nil for an unknown node`() {
        let agg = aggregator([packet(from: 1, packetID: 1)])
        #expect(agg.detail(forNode: 0xDEAD) == nil)
    }

    @Test
    func `why fields mirror the node counters`() {
        // One logical position packet heard by three gateways + one telemetry packet.
        let agg = aggregator([
            packet(from: 7, packetID: 1, port: .position, gatewayID: 0xAA),
            packet(from: 7, packetID: 1, port: .position, gatewayID: 0xBB),
            packet(from: 7, packetID: 1, port: .position, gatewayID: 0xCC),
            packet(from: 7, packetID: 2, port: .telemetry, gatewayID: 0xAA)
        ])
        let detail = agg.detail(forNode: 7)
        #expect(detail?.receptions == 4) // every fold
        #expect(detail?.emitted == 2) // two distinct (from, packetID)
        #expect(detail?.spread == 3) // three distinct gateways
        #expect(detail?.dominantPort?.name == "POSITION_APP") // 3 recv > 1
    }

    @Test
    func `per-port breakdown splits emit and receptions and shares sum to one`() {
        let agg = aggregator([
            packet(from: 7, packetID: 1, port: .position, gatewayID: 0xAA),
            packet(from: 7, packetID: 1, port: .position, gatewayID: 0xBB),
            packet(from: 7, packetID: 2, port: .telemetry, gatewayID: 0xAA)
        ])
        guard let ports = agg.detail(forNode: 7)?.ports else {
            Issue.record("no detail"); return
        }
        // Sorted by receptions descending: position (2) before telemetry (1).
        #expect(ports.map(\.descriptor.name) == ["POSITION_APP", "TELEMETRY_APP"])
        #expect(ports.first?.receptions == 2)
        #expect(ports.first?.emitted == 1) // two floods, one logical packet
        let shareSum = ports.map(\.share).reduce(0, +)
        #expect(abs(shareSum - 1.0) < 0.0001)
    }

    @Test
    func `gateways are the sorted distinct receiving locations`() {
        let agg = aggregator([
            packet(from: 7, packetID: 1, gatewayID: 0xCC),
            packet(from: 7, packetID: 2, gatewayID: 0xAA),
            packet(from: 7, packetID: 3, gatewayID: 0xCC)
        ])
        #expect(agg.detail(forNode: 7)?.gateways == [0xAA, 0xCC])
    }

    @Test
    func `hop range spans the smallest and largest hops seen`() {
        let agg = aggregator([
            packet(from: 7, packetID: 1, hopStart: 3, hopLimit: 1), // 2 hops
            packet(from: 7, packetID: 2, hopStart: 5, hopLimit: 0), // 5 hops
            packet(from: 7, packetID: 3, hopStart: 2, hopLimit: 1) // 1 hop
        ])
        let detail = agg.detail(forNode: 7)
        #expect(detail?.minHops == 1)
        #expect(detail?.maxHops == 5)
        #expect(detail?.hopRangeLabel == "1–5")
    }

    @Test
    func `hop range collapses to a single value when constant`() {
        let agg = aggregator([
            packet(from: 7, packetID: 1, hopStart: 3, hopLimit: 1),
            packet(from: 7, packetID: 2, hopStart: 3, hopLimit: 1)
        ])
        #expect(agg.detail(forNode: 7)?.hopRangeLabel == "2")
    }

    @Test
    func `first and last seen bracket the observed window`() {
        let agg = aggregator([
            packet(from: 7, packetID: 1, at: 10),
            packet(from: 7, packetID: 2, at: 130)
        ])
        let detail = agg.detail(forNode: 7)
        #expect(detail?.firstSeen == Instant.epoch.adding(seconds: 10))
        #expect(detail?.lastSeen == Instant.epoch.adding(seconds: 130))
        #expect(detail?.windowSeconds == 120)
    }

    @Test
    func `activity histogram buckets receptions per minute since first heard`() {
        // First heard at t=0; receptions at 0s, 30s (minute 0) and 70s, 90s (minute 1),
        // then 200s (minute 3) — minute 2 is a silent gap that must be filled with 0.
        let agg = aggregator([
            packet(from: 7, packetID: 1, at: 0),
            packet(from: 7, packetID: 2, at: 30),
            packet(from: 7, packetID: 3, at: 70),
            packet(from: 7, packetID: 4, at: 90),
            packet(from: 7, packetID: 5, at: 200)
        ])
        guard let activity = agg.detail(forNode: 7)?.activity else {
            Issue.record("no detail"); return
        }
        #expect(activity.map(\.minute) == [0, 1, 2, 3])
        #expect(activity.map(\.receptions) == [2, 2, 0, 1])
        #expect(agg.detail(forNode: 7)?.peakActivity == 2)
    }

    @Test
    func `projection and aggregator detail entrypoints agree`() {
        let agg = aggregator([packet(from: 7, packetID: 1)])
        #expect(agg.detail(forNode: 7) == TrafficProjection.offenderDetail(agg, forNode: 7))
    }
}
