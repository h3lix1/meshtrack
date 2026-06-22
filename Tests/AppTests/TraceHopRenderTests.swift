// TraceHopRenderTests — items 2, 3, 6 of the map-trace work.
//
//  - Item 2: edges sharing a hop number animate concurrently (the wavefront expands
//    ring-by-ring), driven by hopIndex rather than edge position.
//  - Item 3/6: the trace model carries per-edge hop numbers and a per-receiver
//    reception hop so the renderer can label each hop and ring every receiver.

@testable import App
import CoreGraphics
import Domain
import Testing

@Suite("Trace hop timing (item 2 — simultaneous same-hop edges)")
struct TraceHopTimingTests {
    private let hopDuration = 1.0

    private func progress(hopIndex: Int, clock: Double, mode: TraceTimingMode = .sequential) -> Double {
        TraceTiming.edgeProgress(
            clock: clock, startedAt: 0, hopIndex: hopIndex,
            hopDuration: hopDuration, mode: mode
        )
    }

    @Test
    func `all edges of the same hop number share identical progress`() {
        // Two hop-1 edges (e.g. parallel paths fanning out of the source) must reveal
        // together — their progress is a function of hop number, not edge position.
        let clock = 0.5
        #expect(progress(hopIndex: 1, clock: clock) == progress(hopIndex: 1, clock: clock))
        // Hop 2 has not started yet at clock 0.5 (delayed one hopDuration).
        #expect(progress(hopIndex: 1, clock: clock) > 0)
        #expect(progress(hopIndex: 2, clock: clock) == 0)
    }

    @Test
    func `hop n is delayed by (n-1) durations, not by edge index`() {
        // Hop 1 completes at clock 1.0; hop 2 starts then and completes at 2.0; hop 3 at 3.0.
        #expect(progress(hopIndex: 1, clock: 1.0) == 1.0)
        #expect(progress(hopIndex: 2, clock: 1.0) == 0.0)
        #expect(progress(hopIndex: 2, clock: 1.5) == 0.5)
        #expect(progress(hopIndex: 3, clock: 2.0) == 0.0)
        #expect(progress(hopIndex: 3, clock: 2.5) == 0.5)
    }

    @Test
    func `equalise finish ignores hop number so all hops land together`() {
        for hop in 1 ... 3 {
            #expect(progress(hopIndex: hop, clock: 0.5, mode: .equaliseFinish) == 0.5)
            #expect(progress(hopIndex: hop, clock: 1.0, mode: .equaliseFinish) == 1.0)
        }
    }
}

@Suite("Per-hop trace model (items 3 + 6)")
struct TraceHopModelTests {
    private let positions: [Int64: GeoPoint] = [
        0x0000_0001: GeoPoint(latitude: 37.0, longitude: -122.0), // source
        0x0000_0011: GeoPoint(latitude: 37.2, longitude: -122.0), // relay (ends in 0x11)
        0x0000_00FF: GeoPoint(latitude: 37.5, longitude: -122.0) // gateway
    ]

    /// A reception of a 2-hop packet relayed through the 0x11 node to the gateway.
    private func reception(hopStart: Int, hopLimit: Int) -> PacketReception {
        PacketReception(
            packetID: 0xAA, fromNode: 0x0000_0001, gatewayNode: 0x0000_00FF,
            relayNode: 0x11, hopStart: hopStart, hopLimit: hopLimit, rxTime: .epoch
        )
    }

    @Test
    func `builder assigns ascending hop indices along the path`() throws {
        let traces = PacketTraceBuilder.build(
            receptions: [reception(hopStart: 3, hopLimit: 1)], positions: positions
        )
        let trace = try #require(traces.first)
        #expect(trace.edges.count == 2)
        #expect(trace.edges.map(\.hopIndex) == [1, 2]) // source→relay = hop 1, relay→gateway = hop 2
        #expect(trace.maxHopIndex == 2)
    }

    @Test
    func `builder surfaces every receiver with its reception hop`() throws {
        let traces = PacketTraceBuilder.build(
            receptions: [reception(hopStart: 3, hopLimit: 1)], positions: positions
        )
        let trace = try #require(traces.first)
        let byID = Dictionary(uniqueKeysWithValues: trace.receivers.map { ($0.nodeID, $0) })
        // The gateway heard it at hop 2; the relay one hop earlier, at hop 1.
        #expect(byID[0x0000_00FF]?.hop == 2)
        #expect(byID[0x0000_00FF]?.isGateway == true)
        #expect(byID[0x0000_0011]?.hop == 1)
        #expect(byID[0x0000_0011]?.isGateway == false)
        // The source is the originator, not a receiver.
        #expect(byID[0x0000_0001] == nil)
    }

    @Test
    func `a direct single-hop reception has one hop-1 edge and a hop-1 gateway`() throws {
        let direct = PacketReception(
            packetID: 0xBB, fromNode: 0x0000_0001, gatewayNode: 0x0000_00FF,
            relayNode: 0, hopStart: 2, hopLimit: 1, rxTime: .epoch
        )
        let trace = try #require(PacketTraceBuilder.build(receptions: [direct], positions: positions).first)
        #expect(trace.edges.map(\.hopIndex) == [1])
        #expect(trace.receivers.count == 1)
        #expect(trace.receivers.first?.hop == 1)
    }
}
