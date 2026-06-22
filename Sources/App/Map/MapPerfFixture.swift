// MapPerfFixture — deterministic Network-map workloads for profiling.
//
// The live MQTT feed is too variable to be a performance contract. These fixtures
// build dense, co-located and bursty map states that can be launched from
// MeshtrackApp and exercised under xctrace.

import Domain

public struct MapPerfData: Sendable, Equatable {
    public let nodes: [NetworkNode]
    public let traces: [PacketTrace]
    public let latencyMillis: [UInt32: Int]

    public init(nodes: [NetworkNode], traces: [PacketTrace], latencyMillis: [UInt32: Int]) {
        self.nodes = nodes
        self.traces = traces
        self.latencyMillis = latencyMillis
    }
}

public enum MapPerfFixture: String, CaseIterable, Sendable {
    case dense
    case colocated
    case burst

    public static func make(_ fixture: MapPerfFixture) -> MapPerfData {
        switch fixture {
        case .dense:
            make(nodeCount: 250, traceCount: 48, colocatedEvery: nil)
        case .colocated:
            make(nodeCount: 300, traceCount: 48, colocatedEvery: 5)
        case .burst:
            make(nodeCount: 1000, traceCount: 96, colocatedEvery: 7)
        }
    }

    public static func make(named name: String) -> MapPerfData? {
        guard let fixture = MapPerfFixture(rawValue: name) else { return nil }
        return make(fixture)
    }

    private static func make(
        nodeCount: Int,
        traceCount: Int,
        colocatedEvery: Int?
    ) -> MapPerfData {
        let nodes = makeNodes(count: nodeCount, colocatedEvery: colocatedEvery)
        let traces = makeTraces(nodes: nodes, count: traceCount)
        let latency = Dictionary(uniqueKeysWithValues: traces.enumerated().map { index, trace in
            (trace.id, 45 + (index * 17) % 240)
        })
        return MapPerfData(nodes: nodes, traces: traces, latencyMillis: latency)
    }

    private static func makeNodes(count: Int, colocatedEvery: Int?) -> [NetworkNode] {
        let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
        let centerLat = 37.7749
        let centerLon = -122.4194
        let latStep = 0.018
        let lonStep = 0.024
        let mastSites = [
            GeoPoint(latitude: 37.7749, longitude: -122.4194),
            GeoPoint(latitude: 37.8044, longitude: -122.2712),
            GeoPoint(latitude: 37.4419, longitude: -122.1430),
            GeoPoint(latitude: 37.9735, longitude: -122.5311)
        ]

        return (0 ..< count).map { index in
            let row = index / columns
            let column = index % columns
            let base = GeoPoint(
                latitude: centerLat + (Double(row) - Double(columns) / 2.0) * latStep,
                longitude: centerLon + (Double(column) - Double(columns) / 2.0) * lonStep
            )
            let position: GeoPoint = if let colocatedEvery, index % colocatedEvery == 0 {
                mastSites[(index / colocatedEvery) % mastSites.count]
            } else {
                base
            }
            return NetworkNode(
                id: Int64(0x7000_0000 + index),
                name: "Perf-\(index)",
                position: position,
                hopsFromGateway: index % 4,
                batteryPercent: Double((index * 13) % 100),
                isGateway: index % 37 == 0,
                preset: index.isMultiple(of: 2) ? .mediumFast : .longFast
            )
        }
    }

    private static func makeTraces(nodes: [NetworkNode], count: Int) -> [PacketTrace] {
        guard nodes.count >= 3 else { return [] }
        let gateways = nodes.filter(\.isGateway)
        return (0 ..< count).map { index in
            let source = nodes[(index * 7 + 3) % nodes.count]
            let relay = nodes[(index * 17 + 11) % nodes.count]
            let gateway = gateways.isEmpty
                ? nodes[(index * 29 + 23) % nodes.count]
                : gateways[index % gateways.count]
            let id = UInt32(0xA000_0000) &+ UInt32(index)
            return PacketTrace(
                id: id,
                sourceNode: source.id,
                edges: [
                    TraceEdge(from: source.position, to: relay.position, kind: .guessed, hopIndex: 1),
                    TraceEdge(from: relay.position, to: gateway.position, kind: .observed, hopIndex: 2)
                ],
                hops: 2,
                startedAt: Double(index % 12) * 0.08,
                receivers: [
                    TraceReceiver(nodeID: relay.id, position: relay.position, hop: 1, isGateway: false),
                    TraceReceiver(nodeID: gateway.id, position: gateway.position, hop: 2, isGateway: true)
                ],
                preset: index.isMultiple(of: 2) ? .mediumFast : .longFast
            )
        }
    }
}
