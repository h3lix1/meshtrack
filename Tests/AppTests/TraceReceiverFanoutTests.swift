@testable import App
import Domain
import Testing

@Suite("Receiver fan-out")
struct ReceiverFanoutTests {
    @Test
    func `fan-out draws an explicit last hop to each positioned observer`() {
        let source = GeoPoint(latitude: 37.0, longitude: -122.0)
        let relay = GeoPoint(latitude: 37.2, longitude: -122.1)
        let observerA = GeoPoint(latitude: 37.4, longitude: -122.2)
        let observerB = GeoPoint(latitude: 37.5, longitude: -122.3)
        let trace = PacketTrace(
            id: 0xCAFE,
            sourceNode: 1,
            edges: [
                TraceEdge(from: source, to: relay, kind: .guessed, hopIndex: 1),
                TraceEdge(from: relay, to: observerA, kind: .observed, hopIndex: 2)
            ],
            hops: 2,
            startedAt: 0,
            receivers: [
                TraceReceiver(nodeID: 2, position: observerA, hop: 2, kind: .gateway),
                TraceReceiver(nodeID: 3, position: observerB, hop: 2, kind: .gateway)
            ]
        )

        let segments = ReceiverFanout.segments(for: trace)

        #expect(segments.count == 2)
        #expect(Set(segments.map(\.receiver.nodeID)) == [2, 3])
        #expect(segments.allSatisfy { $0.from == relay })
    }

    @Test
    func `destination fan-out anchors from the furthest known prior hop`() throws {
        let source = GeoPoint(latitude: 37.0, longitude: -122.0)
        let relay = GeoPoint(latitude: 37.2, longitude: -122.1)
        let gateway = GeoPoint(latitude: 37.4, longitude: -122.2)
        let destination = GeoPoint(latitude: 37.6, longitude: -122.4)
        let trace = PacketTrace(
            id: 0xBEEF,
            sourceNode: 1,
            edges: [
                TraceEdge(from: source, to: relay, kind: .guessed, hopIndex: 1),
                TraceEdge(from: relay, to: gateway, kind: .observed, hopIndex: 2)
            ],
            hops: 3,
            startedAt: 0,
            receivers: [
                TraceReceiver(nodeID: 9, position: destination, hop: 3, kind: .destination)
            ]
        )

        let segment = try #require(ReceiverFanout.segments(for: trace).first)

        #expect(segment.from == gateway)
        #expect(segment.receiver.position == destination)
    }

    @Test
    func `fan-out prefers each receiver's resolved router anchor`() {
        let sharedHopEdgeAnchor = GeoPoint(latitude: 37.0, longitude: -122.0)
        let routerA = GeoPoint(latitude: 37.1, longitude: -122.2)
        let routerB = GeoPoint(latitude: 37.1, longitude: -121.8)
        let listenerA = GeoPoint(latitude: 37.2, longitude: -122.3)
        let listenerB = GeoPoint(latitude: 37.2, longitude: -121.7)
        let trace = PacketTrace(
            id: 0xF00D,
            sourceNode: 1,
            edges: [
                TraceEdge(from: sharedHopEdgeAnchor, to: routerA, kind: .observed, hopIndex: 1)
            ],
            hops: 2,
            startedAt: 0,
            receivers: [
                TraceReceiver(
                    nodeID: 10,
                    position: listenerA,
                    hop: 2,
                    kind: .gateway,
                    heardFromNodeID: 2,
                    heardFromPosition: routerA
                ),
                TraceReceiver(
                    nodeID: 11,
                    position: listenerB,
                    hop: 2,
                    kind: .gateway,
                    heardFromNodeID: 3,
                    heardFromPosition: routerB
                )
            ]
        )

        let byReceiver = Dictionary(uniqueKeysWithValues: ReceiverFanout.segments(for: trace).map {
            ($0.receiver.nodeID, $0.from)
        })

        #expect(byReceiver[10] == routerA)
        #expect(byReceiver[11] == routerB)
    }

    @Test
    func `fan-out does not source-anchor same-hop listeners without a resolved router`() {
        let source = GeoPoint(latitude: 37.0, longitude: -122.0)
        let gateway = GeoPoint(latitude: 37.2, longitude: -122.1)
        let listener = GeoPoint(latitude: 37.4, longitude: -122.3)
        let trace = PacketTrace(
            id: 0xA11C,
            sourceNode: 1,
            edges: [
                TraceEdge(from: source, to: gateway, kind: .observed, hopIndex: 1)
            ],
            hops: 1,
            startedAt: 0,
            receivers: [
                TraceReceiver(nodeID: 12, position: listener, hop: 1, kind: .gateway)
            ]
        )

        #expect(ReceiverFanout.segments(for: trace).isEmpty)
    }
}
