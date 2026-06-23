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
    func `ambiguous relay guesses can be suppressed`() throws {
        let traces = PacketTraceBuilder.build(
            receptions: [reception(relay: 0xAB)],
            positions: positions,
            relayGuessing: .unambiguousOnly
        )
        let trace = try #require(traces.first)
        #expect(trace.edges.map(\.kind) == [.observed])
        #expect(!trace.receivers.contains { $0.kind == .relay })
        #expect(trace.receivers.contains { $0.nodeID == 0x0000_00FF && $0.kind == .gateway })
    }

    @Test
    func `all relay collisions can be included as candidate legs`() throws {
        let traces = PacketTraceBuilder.build(
            receptions: [reception(relay: 0xAB)],
            positions: positions,
            relayGuessing: .allCandidates
        )
        let trace = try #require(traces.first)
        let gateway = try #require(positions[0x0000_00FF])
        let near = try #require(positions[0x0000_11AB])
        let far = try #require(positions[0x0000_22AB])

        #expect(trace.edges.map(\.kind) == [.guessed, .observed, .guessed, .observed])
        #expect(trace.receivers.filter { $0.kind == .relay }.map(\.nodeID) == [
            0x0000_11AB,
            0x0000_22AB
        ])
        #expect(trace.edges.filter { $0.to == gateway }.map(\.from) == [near, far])
    }

    @Test
    func `unambiguous relay guesses are kept when ambiguity suppression is enabled`() throws {
        var oneCandidate = positions
        oneCandidate[0x0000_22AB] = nil

        let traces = PacketTraceBuilder.build(
            receptions: [reception(relay: 0xAB)],
            positions: oneCandidate,
            relayGuessing: .unambiguousOnly
        )
        let trace = try #require(traces.first)
        #expect(trace.edges.map(\.kind) == [.guessed, .observed])
        let relay = try #require(trace.receivers.first { $0.kind == .relay })
        #expect(relay.nodeID == 0x0000_11AB)
    }

    @Test
    func `no relay hint yields a single observed edge`() {
        let traces = PacketTraceBuilder.build(receptions: [reception(relay: 0)], positions: positions)
        #expect(traces.first?.edges.map(\.kind) == [.observed])
    }

    @Test
    func `relay guessing skips a CLIENT_MUTE candidate and picks the next nearest`() throws {
        // 0x11AB is the nearest AB-ending node but is CLIENT_MUTE (never rebroadcasts),
        // so the guess falls through to the next candidate, 0x22AB.
        let guess = try PacketTraceBuilder.guessRelay(
            relayByte: 0xAB, excluding: [0x0000_0001, 0x0000_00FF],
            positions: positions, near: #require(positions[0x0000_00FF]),
            nonRelayNodes: [0x0000_11AB]
        )
        #expect(guess == 0x0000_22AB)
    }

    @Test
    func `a CLIENT_MUTE node is never guessed as a relay`() throws {
        // Both AB-ending candidates are CLIENT_MUTE — there is no one left to relay, so the
        // packet falls back to a single direct source→gateway edge with no relay receiver.
        let traces = PacketTraceBuilder.build(
            receptions: [reception(relay: 0xAB)],
            positions: positions,
            nonRelayNodes: [0x0000_11AB, 0x0000_22AB]
        )
        let trace = try #require(traces.first)
        #expect(trace.edges.map(\.kind) == [.observed])
        #expect(!trace.receivers.contains { $0.kind == .relay })
    }

    @Test
    func `a CLIENT_MUTE node can still be the addressed destination (last hop)`() throws {
        // Unicast addressed to the mute node 0x11AB: it must still surface as the
        // destination/last-hop receiver even though it is barred from relay guesses.
        let unicast = PacketReception(
            packetID: 0xABCD, fromNode: 0x0000_0001, toNode: 0x0000_11AB,
            gatewayNode: 0x0000_00FF, relayNode: 0, hopStart: 2, hopLimit: 1, rxTime: .epoch
        )
        let traces = PacketTraceBuilder.build(
            receptions: [unicast], positions: positions, nonRelayNodes: [0x0000_11AB]
        )
        let trace = try #require(traces.first)
        #expect(trace.receivers.contains { $0.nodeID == 0x0000_11AB && $0.kind == .destination })
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

    @Test
    func `multi-hop reports chain node to node instead of restarting at the source`() throws {
        let source = Int64(0x0000_0001)
        let routerA = Int64(0x0000_0011)
        let routerB = Int64(0x0000_0022)
        let listener = Int64(0x0000_0033)
        let positions: [Int64: GeoPoint] = [
            source: GeoPoint(latitude: 37.0, longitude: -122.0),
            routerA: GeoPoint(latitude: 37.1, longitude: -122.1),
            routerB: GeoPoint(latitude: 37.2, longitude: -122.2),
            listener: GeoPoint(latitude: 37.3, longitude: -122.3)
        ]
        let firstHop = PacketReception(
            packetID: 0xDD, fromNode: source, gatewayNode: routerA,
            relayNode: 0, hopStart: 3, hopLimit: 2, rxTime: .epoch
        )
        let secondHop = PacketReception(
            packetID: 0xDD, fromNode: source, gatewayNode: routerB,
            relayNode: 0x11, hopStart: 3, hopLimit: 1, rxTime: .epoch
        )
        let thirdHop = PacketReception(
            packetID: 0xDD, fromNode: source, gatewayNode: listener,
            relayNode: 0x22, hopStart: 3, hopLimit: 0, rxTime: .epoch
        )

        let trace = try #require(
            PacketTraceBuilder.build(
                receptions: [thirdHop, secondHop, firstHop],
                positions: positions
            ).first
        )

        #expect(trace.edges.map(\.from) == [
            positions[source],
            positions[routerA],
            positions[routerB]
        ])
        #expect(trace.edges.map(\.to) == [
            positions[routerA],
            positions[routerB],
            positions[listener]
        ])
        #expect(trace.edges.map(\.hopIndex) == [1, 2, 3])
    }

    @Test
    func `a flood with no relay hints chains gateway to gateway by hop`() throws {
        // A flood reported by three gateways at hops 1/2/3 with NO relay hints. Each report
        // should chain onto the nearest node known to have arrived one hop earlier, not
        // spring straight back from the source (the "everything radiates from the source"
        // bug). Nodes are colinear so the nearest previous hop is unambiguous.
        let source = Int64(0x0000_0001)
        let gateway1 = Int64(0x0000_0010)
        let gateway2 = Int64(0x0000_0020)
        let gateway3 = Int64(0x0000_0030)
        let positions: [Int64: GeoPoint] = [
            source: GeoPoint(latitude: 37.0, longitude: -122.0),
            gateway1: GeoPoint(latitude: 37.1, longitude: -122.0),
            gateway2: GeoPoint(latitude: 37.2, longitude: -122.0),
            gateway3: GeoPoint(latitude: 37.3, longitude: -122.0)
        ]
        func hop(_ gateway: Int64, hopLimit: Int) -> PacketReception {
            PacketReception(
                packetID: 0xF100D, fromNode: source, gatewayNode: gateway,
                relayNode: 0, hopStart: 4, hopLimit: hopLimit, rxTime: .epoch
            )
        }
        let receptions = [hop(gateway3, hopLimit: 1), hop(gateway1, hopLimit: 3), hop(gateway2, hopLimit: 2)]

        let trace = try #require(PacketTraceBuilder.build(receptions: receptions, positions: positions).first)

        #expect(trace.edges.map(\.from) == [positions[source], positions[gateway1], positions[gateway2]])
        #expect(trace.edges.map(\.to) == [positions[gateway1], positions[gateway2], positions[gateway3]])
        #expect(trace.edges.map(\.hopIndex) == [1, 2, 3])
    }

    @Test
    func `a lone multi-hop report is drawn as a first-hop segment, not a later hop off the source`() throws {
        // The source only transmits the first hop, so a hop-2 report must never be drawn as
        // a later-hop edge leaving the source (that reads as the source re-sending). With no
        // intermediate node known we can't decompose the path, so it's drawn as a single
        // first-hop segment — visible, but never implying the source re-sent at hop 2.
        let source = Int64(0x0000_0001)
        let gateway = Int64(0x0000_00FF)
        let positions: [Int64: GeoPoint] = [
            source: GeoPoint(latitude: 37.0, longitude: -122.0),
            gateway: GeoPoint(latitude: 37.5, longitude: -122.0)
        ]
        let reception = PacketReception(
            packetID: 0xBADF00D, fromNode: source, gatewayNode: gateway,
            relayNode: 0, hopStart: 3, hopLimit: 1, rxTime: .epoch
        )

        let trace = try #require(PacketTraceBuilder.build(receptions: [reception], positions: positions).first)

        #expect(trace.edges.map(\.from) == [positions[source]])
        #expect(trace.edges.map(\.to) == [positions[gateway]])
        #expect(trace.edges.map(\.hopIndex) == [1]) // an undecomposable 2-hop path, drawn as one first-hop segment
        #expect(trace.hops == 2) // the true hop count is still reported on the badge
    }

    @Test
    func `the source only ever originates first-hop edges, even for undecomposable orphans`() throws {
        // Two gateways heard a 2-hop flood with no relay hint and no known hop-1 node to
        // chain onto. We can't decompose the path, but we must NEVER draw a hop-2 edge off
        // the source — each is shown as a first-hop segment instead.
        let source = Int64(0x0000_0001)
        let gatewayA = Int64(0x0000_00FF)
        let gatewayB = Int64(0x0000_00EE)
        let positions: [Int64: GeoPoint] = [
            source: GeoPoint(latitude: 37.0, longitude: -122.0),
            gatewayA: GeoPoint(latitude: 37.5, longitude: -122.0),
            gatewayB: GeoPoint(latitude: 37.3, longitude: -121.8)
        ]
        func hop2(_ gateway: Int64) -> PacketReception {
            PacketReception(
                packetID: 0x0FF1CE, fromNode: source, gatewayNode: gateway,
                relayNode: 0, hopStart: 3, hopLimit: 1, rxTime: .epoch
            )
        }

        let trace = try #require(
            PacketTraceBuilder.build(receptions: [hop2(gatewayA), hop2(gatewayB)], positions: positions).first
        )
        let sourcePosition = try #require(positions[source])

        #expect(trace.edges.count == 2)
        #expect(trace.edges.allSatisfy { $0.from == sourcePosition })
        #expect(trace.edges.allSatisfy { $0.hopIndex == 1 }) // no later-hop edge leaves the source
        #expect(trace.hops == 2) // true hop count preserved
    }

    @Test
    func `a deep relay chains onto a known earlier hop instead of floating`() throws {
        // A hop-3 report whose guessed relay sits at hop 2. The edge feeding that relay
        // should start at the nearest node known to have arrived at hop 1 (chaining the
        // whole path back to the source) rather than leaving the relay floating.
        let source = Int64(0x0000_0001)
        let routerA = Int64(0x0000_0011) // hop-1 node, reached via a hint-less report
        let relayB = Int64(0x0000_0022) // the guessed relay at hop 2 (id ends in 0x22)
        let gateway = Int64(0x0000_00FF)
        let positions: [Int64: GeoPoint] = [
            source: GeoPoint(latitude: 37.0, longitude: -122.0),
            routerA: GeoPoint(latitude: 37.1, longitude: -122.0),
            relayB: GeoPoint(latitude: 37.2, longitude: -122.0),
            gateway: GeoPoint(latitude: 37.3, longitude: -122.0)
        ]
        let firstHop = PacketReception(
            packetID: 0xC0DE, fromNode: source, gatewayNode: routerA,
            relayNode: 0, hopStart: 4, hopLimit: 3, rxTime: .epoch
        )
        let thirdHop = PacketReception(
            packetID: 0xC0DE, fromNode: source, gatewayNode: gateway,
            relayNode: 0x22, hopStart: 4, hopLimit: 1, rxTime: .epoch
        )

        let trace = try #require(
            PacketTraceBuilder.build(receptions: [thirdHop, firstHop], positions: positions).first
        )

        #expect(trace.edges.map(\.from) == [positions[source], positions[routerA], positions[relayB]])
        #expect(trace.edges.map(\.to) == [positions[routerA], positions[relayB], positions[gateway]])
        #expect(trace.edges.map(\.hopIndex) == [1, 2, 3])
        #expect(trace.edges.map(\.kind) == [.observed, .guessed, .observed])
    }

    @Test
    func `same-hop listeners keep the router they actually heard from`() throws {
        let source = Int64(0x0000_0001)
        let routerA = Int64(0x0000_0011)
        let routerB = Int64(0x0000_0022)
        let listenerA = Int64(0x0000_00A1)
        let listenerB = Int64(0x0000_00B2)
        let positions: [Int64: GeoPoint] = [
            source: GeoPoint(latitude: 37.0, longitude: -122.0),
            routerA: GeoPoint(latitude: 37.1, longitude: -122.1),
            routerB: GeoPoint(latitude: 37.1, longitude: -121.9),
            listenerA: GeoPoint(latitude: 37.2, longitude: -122.2),
            listenerB: GeoPoint(latitude: 37.2, longitude: -121.8)
        ]
        let receptions = [
            PacketReception(
                packetID: 0xEE, fromNode: source, gatewayNode: routerA,
                relayNode: 0, hopStart: 3, hopLimit: 2, rxTime: .epoch
            ),
            PacketReception(
                packetID: 0xEE, fromNode: source, gatewayNode: routerB,
                relayNode: 0, hopStart: 3, hopLimit: 2, rxTime: .epoch
            ),
            PacketReception(
                packetID: 0xEE, fromNode: source, gatewayNode: listenerA,
                relayNode: 0x11, hopStart: 3, hopLimit: 1, rxTime: .epoch
            ),
            PacketReception(
                packetID: 0xEE, fromNode: source, gatewayNode: listenerB,
                relayNode: 0x22, hopStart: 3, hopLimit: 1, rxTime: .epoch
            )
        ]

        let trace = try #require(PacketTraceBuilder.build(receptions: receptions, positions: positions).first)
        let receiverA = try #require(trace.receivers.first { $0.nodeID == listenerA })
        let receiverB = try #require(trace.receivers.first { $0.nodeID == listenerB })

        #expect(receiverA.heardFromNodeID == routerA)
        #expect(receiverA.heardFromPosition == positions[routerA])
        #expect(receiverB.heardFromNodeID == routerB)
        #expect(receiverB.heardFromPosition == positions[routerB])
    }
}
