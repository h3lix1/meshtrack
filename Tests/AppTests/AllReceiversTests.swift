// AllReceiversTests — "show all receivers" must surface every node we have EVIDENCE
// received the packet (item 8):
//   - the addressed destination (DecodedPacket.to) as the last/furthest hop,
//   - every distinct reporting gateway (positioned → drawn; unpositioned → listed),
//   - the guessed relay(s),
// and NOT silently drop receivers we have no position for. The honest limitation —
// silent overhearers are unknowable — is encoded by these tests NOT expecting any
// fabricated receiver beyond the reported gateways, guessed relays, and destination.

@testable import App
import Domain
import Testing

@Suite("All receivers — destination + unpositioned (item 8)")
struct AllReceiversTests {
    /// source 0x..01, a relay ending 0x11, gateway 0x..FF, destination 0x..D5.
    private let positions: [Int64: GeoPoint] = [
        0x0000_0001: GeoPoint(latitude: 37.0, longitude: -122.0), // source
        0x0000_0011: GeoPoint(latitude: 37.2, longitude: -122.0), // relay (ends 0x11)
        0x0000_00FF: GeoPoint(latitude: 37.5, longitude: -122.0), // gateway
        0x0000_00D5: GeoPoint(latitude: 37.6, longitude: -122.0) // destination
    ]

    private func reception(
        to: Int64?, gateway: Int64? = 0x0000_00FF, relay: UInt8 = 0x11,
        hopStart: Int = 3, hopLimit: Int = 1
    ) -> PacketReception {
        PacketReception(
            packetID: 0xAA, fromNode: 0x0000_0001, toNode: to, gatewayNode: gateway,
            relayNode: relay, hopStart: hopStart, hopLimit: hopLimit, rxTime: .epoch
        )
    }

    @Test
    func `the addressed destination is a receiver at the max hop, distinctly styled`() throws {
        let traces = PacketTraceBuilder.build(
            receptions: [reception(to: 0x0000_00D5)], positions: positions
        )
        let trace = try #require(traces.first)
        let destination = try #require(trace.receivers.first { $0.nodeID == 0x0000_00D5 })
        #expect(destination.kind == .destination)
        #expect(destination.isDestination)
        // 2 hops (hopStart 3 - hopLimit 1) → destination tagged with the furthest hop.
        #expect(destination.hop == 2)
    }

    @Test
    func `a broadcast destination is NOT marked as a receiver`() throws {
        for broadcast: Int64 in [0, 0xFFFF_FFFF] {
            let traces = PacketTraceBuilder.build(
                receptions: [reception(to: broadcast)], positions: positions
            )
            let trace = try #require(traces.first)
            #expect(!trace.receivers.contains { $0.kind == .destination })
            #expect(!trace.unpositionedReceivers.contains { $0.kind == .destination })
        }
    }

    @Test
    func `a self-addressed destination is not marked`() throws {
        let traces = PacketTraceBuilder.build(
            receptions: [reception(to: 0x0000_0001)], positions: positions
        )
        let trace = try #require(traces.first)
        #expect(!trace.receivers.contains { $0.kind == .destination })
    }

    @Test
    func `a destination without a known position is listed, not dropped`() throws {
        // 0x0000_BEEF has no entry in positions → it can't be drawn but must be listed.
        let traces = PacketTraceBuilder.build(
            receptions: [reception(to: 0x0000_BEEF)], positions: positions
        )
        let trace = try #require(traces.first)
        #expect(!trace.receivers.contains { $0.nodeID == 0x0000_BEEF })
        let listed = try #require(trace.unpositionedReceivers.first { $0.nodeID == 0x0000_BEEF })
        #expect(listed.kind == .destination)
        #expect(listed.hop == 2)
    }

    @Test
    func `an unpositioned gateway is listed rather than silently dropped`() throws {
        // Gateway 0x0000_AAAA has no position; it still reported the packet, so it must
        // surface in the textual list (item 8 §2). The 0xFF gateway draws as before.
        let viaKnown = reception(to: 0x0000_00D5, gateway: 0x0000_00FF)
        let viaUnknown = reception(to: 0x0000_00D5, gateway: 0x0000_AAAA, relay: 0)
        let traces = PacketTraceBuilder.build(
            receptions: [viaKnown, viaUnknown], positions: positions
        )
        let trace = try #require(traces.first)
        #expect(trace.receivers.contains { $0.nodeID == 0x0000_00FF && $0.isGateway })
        let listed = try #require(trace.unpositionedReceivers.first { $0.nodeID == 0x0000_AAAA })
        #expect(listed.kind == .gateway)
    }

    @Test
    func `every distinct reporting gateway with a position appears as a receiver`() throws {
        // Two positioned gateways report the same packet id → both must ring.
        let positions = positions.merging([0x0000_00EE: GeoPoint(
            latitude: 37.55,
            longitude: -122.0
        )]) { _, new in new }
        let viaA = reception(to: 0x0000_00D5, gateway: 0x0000_00FF, relay: 0)
        let viaB = reception(to: 0x0000_00D5, gateway: 0x0000_00EE, relay: 0)
        let traces = PacketTraceBuilder.build(receptions: [viaA, viaB], positions: positions)
        let trace = try #require(traces.first)
        let gatewayIDs = Set(trace.receivers.filter(\.isGateway).map(\.nodeID))
        #expect(gatewayIDs == [0x0000_00FF, 0x0000_00EE])
    }

    @Test
    func `the guessed relay is a non-gateway receiver one hop before the gateway`() throws {
        let traces = PacketTraceBuilder.build(
            receptions: [reception(to: 0x0000_00D5)], positions: positions
        )
        let trace = try #require(traces.first)
        let relay = try #require(trace.receivers.first { $0.nodeID == 0x0000_0011 })
        #expect(relay.kind == .relay)
        #expect(!relay.isGateway)
        #expect(relay.hop == 1) // gateway is hop 2, relay one earlier
    }

    @Test
    func `back-compat init maps isGateway true to the gateway kind`() {
        let position = GeoPoint(latitude: 1, longitude: 1)
        let gateway = TraceReceiver(nodeID: 1, position: position, hop: 1, isGateway: true)
        let relay = TraceReceiver(nodeID: 2, position: position, hop: 1, isGateway: false)
        #expect(gateway.kind == .gateway)
        #expect(relay.kind == .relay)
    }
}

@Suite("VizLegend.receivedBy — complete reported roster (item 8)")
struct ReceivedByTests {
    private let positions: [Int64: GeoPoint] = [
        0x0000_0001: GeoPoint(latitude: 37.0, longitude: -122.0),
        0x0000_00FF: GeoPoint(latitude: 37.5, longitude: -122.0),
        0x0000_00D5: GeoPoint(latitude: 37.6, longitude: -122.0)
    ]

    private func trace() throws -> PacketTrace {
        // Two receptions: one via a positioned gateway, one via an unpositioned gateway,
        // addressed to a positioned destination.
        let viaKnown = PacketReception(
            packetID: 0xBB, fromNode: 0x0000_0001, toNode: 0x0000_00D5,
            gatewayNode: 0x0000_00FF, relayNode: 0, hopStart: 2, hopLimit: 1, rxTime: .epoch
        )
        let viaUnknown = PacketReception(
            packetID: 0xBB, fromNode: 0x0000_0001, toNode: 0x0000_00D5,
            gatewayNode: 0x0000_CAFE, relayNode: 0, hopStart: 2, hopLimit: 1, rxTime: .epoch
        )
        return try #require(
            PacketTraceBuilder.build(receptions: [viaKnown, viaUnknown], positions: positions).first
        )
    }

    @Test
    func `roster includes both drawn and listed receivers, sorted by hop then id`() throws {
        let rows = try VizLegend.receivedBy(trace())
        let ids = rows.map(\.nodeID)
        // gateway (drawn), unpositioned gateway (listed), destination (drawn) all present.
        #expect(Set(ids) == [0x0000_00FF, 0x0000_CAFE, 0x0000_00D5])
        // Sorted by hop ascending; the gateways at hop 1 precede the destination at hop 1
        // too, so ties break by node id — verify a stable non-decreasing hop order.
        #expect(rows.map(\.hop) == rows.map(\.hop).sorted())
    }

    @Test
    func `large rosters remain ordered by reception hop then node id`() {
        let point = GeoPoint(latitude: 37.0, longitude: -122.0)
        let positioned = (0 ..< 80).reversed().map { index in
            TraceReceiver(
                nodeID: Int64(0x0001_0000 + index),
                position: point,
                hop: index % 8 + 1,
                kind: index.isMultiple(of: 3) ? .gateway : .relay
            )
        }
        let unpositioned = (80 ..< 130).reversed().map { index in
            UnpositionedReceiver(
                nodeID: Int64(0x0001_0000 + index),
                hop: index % 8 + 1,
                kind: index.isMultiple(of: 5) ? .destination : .relay
            )
        }
        let trace = PacketTrace(
            id: 0xCAFE_BABE,
            sourceNode: 0x0000_0001,
            edges: [],
            hops: 8,
            startedAt: 0,
            receivers: positioned,
            unpositionedReceivers: unpositioned
        )

        let rows = VizLegend.receivedBy(trace)
        #expect(rows.count == 130)
        #expect(rows.map(\.onMap).contains(true))
        #expect(rows.map(\.onMap).contains(false))

        for (previous, next) in zip(rows, rows.dropFirst()) {
            let ordered = previous.hop < next.hop
                || (previous.hop == next.hop && previous.nodeID < next.nodeID)
            #expect(ordered)
        }
    }

    @Test
    func `onMap flag distinguishes drawn from listed-only receivers`() throws {
        let rows = try VizLegend.receivedBy(trace())
        let drawn = try #require(rows.first { $0.nodeID == 0x0000_00FF })
        let listed = try #require(rows.first { $0.nodeID == 0x0000_CAFE })
        #expect(drawn.onMap)
        #expect(!listed.onMap)
    }

    @Test
    func `role labels are honest about how each receiver is known`() {
        let gateway = VizLegend.ReceiverRow(nodeID: 1, hop: 1, kind: .gateway, onMap: true)
        let relay = VizLegend.ReceiverRow(nodeID: 2, hop: 1, kind: .relay, onMap: true)
        let destination = VizLegend.ReceiverRow(nodeID: 3, hop: 2, kind: .destination, onMap: false)
        #expect(gateway.roleLabel == "gateway")
        #expect(relay.roleLabel.contains("relay")) // marked guessed
        #expect(destination.roleLabel == "destination")
        // Node-id label follows the Meshtastic "!hex" convention.
        #expect(gateway.label == "!00000001")
    }

    @Test
    func `an empty trace yields an empty roster`() {
        let empty = PacketTrace(id: 1, sourceNode: 1, edges: [], hops: 0, startedAt: 0)
        #expect(VizLegend.receivedBy(empty).isEmpty)
    }
}
