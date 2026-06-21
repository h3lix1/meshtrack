// ChannelFilter — the map's per-channel filter state + the pure filtering it drives
// (Task 4). The user picks a ChannelPreset (or "All"); nodes not on that channel and
// traces whose source node isn't on it are hidden.
//
// The filtering is a pure static function over NetworkNode/PacketTrace so it is
// unit-tested headless; the observable holds only the current selection.

import Foundation
import Observation

@MainActor
@Observable
public final class ChannelFilter {
    /// The selected preset, or nil for "All channels".
    public var selection: ChannelPreset?

    public init(selection: ChannelPreset? = nil) {
        self.selection = selection
    }

    /// Nodes visible under the current selection (all when nil).
    public func nodes(_ nodes: [NetworkNode]) -> [NetworkNode] {
        Self.filterNodes(nodes, selection: selection)
    }

    /// Traces visible under the current selection: those whose source node is on the
    /// selected channel. All traces when nil.
    public func traces(_ traces: [PacketTrace], nodes: [NetworkNode]) -> [PacketTrace] {
        Self.filterTraces(traces, nodes: nodes, selection: selection)
    }

    // MARK: Pure filtering

    public static func filterNodes(
        _ nodes: [NetworkNode],
        selection: ChannelPreset?
    ) -> [NetworkNode] {
        guard let selection else { return nodes }
        return nodes.filter { $0.preset == selection }
    }

    public static func filterTraces(
        _ traces: [PacketTrace],
        nodes: [NetworkNode],
        selection: ChannelPreset?
    ) -> [PacketTrace] {
        guard let selection else { return traces }
        let onChannel = Set(
            nodes.filter { $0.preset == selection }.map(\.id)
        )
        return traces.filter { onChannel.contains($0.sourceNode) }
    }
}
