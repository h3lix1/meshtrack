// PacketFocus — "isolate one packet" geometry for the live map (focus interaction).
//
// Tapping a packet in the legend focuses it: the map then shows ONLY that packet's
// trace(s) and ONLY the nodes that packet touches — its source node plus the nodes
// sitting at its edge endpoints. Tapping the focused row again (or "Show all") clears
// the focus.
//
// The selection itself is a single optional packet id; the narrowing is a pure static
// function over the node/trace sets so it composes cleanly after the channel filter and
// is unit-tested headless. nil focus is the identity (everything passes through).

import Domain
import Foundation

public enum PacketFocus {
    /// Nodes a focused packet touches: its source node, plus the nodes whose position
    /// sits at one of the focused trace's edge endpoints. Returned in the input order
    /// so marker identity / layout stays stable.
    ///
    /// With `selectedPacketID == nil` this is the identity — all nodes pass through.
    public static func focusNodes(
        _ nodes: [NetworkNode],
        traces: [PacketTrace],
        selectedPacketID: UInt32?
    ) -> [NetworkNode] {
        guard let selectedPacketID else { return nodes }
        let focused = traces.filter { $0.id == selectedPacketID }
        guard !focused.isEmpty else { return [] }

        let sourceIDs = Set(focused.map(\.sourceNode))
        let endpoints = endpointKeys(of: focused)
        // Every node that received the packet stays visible too, so the all-receivers
        // overlay (item 6) can ring last-hop nodes that heard it but never appear as an
        // edge endpoint.
        let receiverIDs = Set(focused.flatMap(\.receivers).map(\.nodeID))

        return nodes.filter { node in
            sourceIDs.contains(node.id)
                || receiverIDs.contains(node.id)
                || endpoints.contains(positionKey(node.position))
        }
    }

    /// Traces a focused packet contributes: only the trace(s) carrying the selected id.
    /// With `selectedPacketID == nil` this is the identity — all traces pass through.
    public static func focusTraces(
        _ traces: [PacketTrace],
        selectedPacketID: UInt32?
    ) -> [PacketTrace] {
        guard let selectedPacketID else { return traces }
        return traces.filter { $0.id == selectedPacketID }
    }

    /// True when the given packet id is what's currently focused — for highlighting the
    /// legend row and toggling focus off on a repeat tap.
    public static func isFocused(_ id: UInt32, selectedPacketID: UInt32?) -> Bool {
        selectedPacketID == id
    }

    /// Toggle focus for a tapped packet id: focusing it, or clearing focus if it is
    /// already the focused one (tap-again-to-reset).
    public static func toggled(_ id: UInt32, current: UInt32?) -> UInt32? {
        current == id ? nil : id
    }

    // MARK: Endpoint matching

    /// The set of edge-endpoint position keys across the focused traces.
    private static func endpointKeys(of traces: [PacketTrace]) -> Set<PositionKey> {
        var keys: Set<PositionKey> = []
        for trace in traces {
            for edge in trace.edges {
                keys.insert(positionKey(edge.from))
                keys.insert(positionKey(edge.to))
            }
        }
        return keys
    }

    /// A rounded lat/long pair, so a node's stored position matches an edge endpoint
    /// built from the same coordinate despite float round-tripping. ~1e-7° ≈ 1cm.
    private struct PositionKey: Hashable {
        let lat: Int64
        let lon: Int64
    }

    private static func positionKey(_ point: GeoPoint) -> PositionKey {
        PositionKey(
            lat: Int64((point.latitude * 1e7).rounded()),
            lon: Int64((point.longitude * 1e7).rounded())
        )
    }
}
