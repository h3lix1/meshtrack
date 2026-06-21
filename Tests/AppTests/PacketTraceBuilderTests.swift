@testable import App
import Domain
import Testing

@Suite("PacketTraceBuilder (relay guessing)")
struct PacketTraceBuilderTests {
    /// Source 0x..01, gateway 0x..FF, two candidate relayers ending in 0xAB.
    private let positions: [Int64: GeoPoint] = [
        0x0000_0001: GeoPoint(latitude: 37.0, longitude: -122.0), // source
        0x0000_00FF: GeoPoint(latitude: 37.5, longitude: -122.0), // gateway
        0x0000_11AB: GeoPoint(latitude: 37.4, longitude: -122.0), // relayer near gateway (ends AB)
        0x0000_22AB: GeoPoint(latitude: 37.1, longitude: -122.0) // relayer far from gateway (ends AB)
    ]

    private func reception(relay: UInt8, hopStart: Int = 3, hopLimit: Int = 1) -> PacketReception {
        PacketReception(
            packetID: 0xABCD, fromNode: 0x0000_0001, gatewayNode: 0x0000_00FF,
            relayNode: relay, hopStart: hopStart, hopLimit: hopLimit, rxTime: .epoch
        )
    }

    @Test
    func `a relayed packet gets a guessed edge then an observed edge`() throws {
        let traces = PacketTraceBuilder.build(receptions: [reception(relay: 0xAB)], positions: positions)
        let trace = try #require(traces.first)
        #expect(trace.edges.map(\.kind) == [.guessed, .observed])
        #expect(trace.hops == 2)
    }

    @Test
    func `relay guessing picks the candidate nearest the gateway`() throws {
        let near = try PacketTraceBuilder.guessRelay(
            relayByte: 0xAB, excluding: [0x0000_0001, 0x0000_00FF],
            positions: positions, near: #require(positions[0x0000_00FF])
        )
        #expect(near == 0x0000_11AB) // the closer of the two AB-ending nodes
    }

    @Test
    func `no relay hint yields a single observed edge`() {
        let traces = PacketTraceBuilder.build(receptions: [reception(relay: 0)], positions: positions)
        #expect(traces.first?.edges.map(\.kind) == [.observed])
    }

    @Test
    func `a source without a known position is skipped`() {
        let reception = PacketReception(
            packetID: 1, fromNode: 0xDEAD, gatewayNode: 0x0000_00FF,
            relayNode: 0, hopStart: 1, hopLimit: 1, rxTime: .epoch
        )
        #expect(PacketTraceBuilder.build(receptions: [reception], positions: positions).isEmpty)
    }

    @Test
    func `the same packet via two gateways yields two journeys' edges`() {
        let viaA = reception(relay: 0)
        var viaB = reception(relay: 0)
        viaB = PacketReception(
            packetID: 0xABCD, fromNode: 0x0000_0001, gatewayNode: 0x0000_11AB,
            relayNode: 0, hopStart: 3, hopLimit: 2, rxTime: .epoch
        )
        let traces = PacketTraceBuilder.build(receptions: [viaA, viaB], positions: positions)
        #expect(traces.first?.edges.count == 2) // one observed edge per gateway
    }
}
