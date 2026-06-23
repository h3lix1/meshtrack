// ReceiverFanout — pure geometry for the "Show all receivers" observer spokes.
// It derives explicit last-hop fan-out segments from the known packet path to each
// positioned receiver so observer-only nodes are drawn, not just listed.

import Domain

public struct ReceiverFanoutSegment: Sendable, Equatable {
    public let from: GeoPoint
    public let receiver: TraceReceiver

    public init(from: GeoPoint, receiver: TraceReceiver) {
        self.from = from
        self.receiver = receiver
    }
}

public enum ReceiverFanout {
    public static func segments(for trace: PacketTrace) -> [ReceiverFanoutSegment] {
        trace.receivers.compactMap { receiver in
            guard let anchor = receiver.heardFromPosition ?? receiverAnchor(
                for: receiver,
                edges: trace.edges
            ),
                positionKey(anchor) != positionKey(receiver.position)
            else { return nil }
            return ReceiverFanoutSegment(from: anchor, receiver: receiver)
        }
    }

    private static func receiverAnchor(for receiver: TraceReceiver, edges: [TraceEdge]) -> GeoPoint? {
        let priorEdges = edges.filter { $0.hopIndex < receiver.hop }
        if let prior = priorEdges.max(by: { $0.hopIndex < $1.hopIndex }) {
            return prior.to
        }

        let currentEdges = edges.filter {
            $0.hopIndex == receiver.hop
                && positionKey($0.to) == positionKey(receiver.position)
        }
        if let current = currentEdges.min(by: {
            Haversine.distanceMeters(from: $0.to, to: receiver.position)
                < Haversine.distanceMeters(from: $1.to, to: receiver.position)
        }) {
            return current.from
        }

        return nil
    }

    private static func positionKey(_ point: GeoPoint) -> PositionKey {
        PositionKey(
            lat: Int64((point.latitude * 1e7).rounded()),
            lon: Int64((point.longitude * 1e7).rounded())
        )
    }

    private struct PositionKey: Hashable {
        let lat: Int64
        let lon: Int64
    }
}
