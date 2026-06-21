// TraceOverlayCanvas — the transparent SwiftUI Canvas that draws the animated packet
// traces, node glows, hop badges and latency tooltips *on top of* the live MKMapView
// (ADR 0007). It owns no geometry of its own: it reads the current MapProjection from
// the shared MeshMapState (refreshed on every camera move) and paints through the
// shared TraceRenderer — the exact same drawing the headless Canvas snapshot uses.
//
// It re-renders on two clocks: the map's `regionRevision` (pan/zoom) and a
// TimelineView(.animation) tick (the trace animation). `allowsHitTesting(false)` lets
// pan/zoom fall through to the map underneath.

#if canImport(MapKit) && os(macOS)
import Domain
import SwiftUI

public struct TraceOverlayCanvas: View {
    public let nodes: [NetworkNode]
    public let traces: [PacketTrace]
    public let state: MeshMapState
    public var clock: Double
    public var hopDuration: Double
    public var mode: TraceTimingMode
    /// Optional receive→publish latency (ms) per packet id, surfaced as edge tooltips.
    public var latencyMillis: [UInt32: Int]

    public init(
        nodes: [NetworkNode],
        traces: [PacketTrace],
        state: MeshMapState,
        clock: Double,
        hopDuration: Double,
        mode: TraceTimingMode,
        latencyMillis: [UInt32: Int] = [:]
    ) {
        self.nodes = nodes
        self.traces = traces
        self.state = state
        self.clock = clock
        self.hopDuration = hopDuration
        self.mode = mode
        self.latencyMillis = latencyMillis
    }

    public var body: some View {
        Canvas { context, _ in
            // Reading regionRevision inside the Canvas closure makes the overlay
            // re-render whenever the map's camera moves.
            _ = state.regionRevision
            guard let projection = state.projection else { return }
            let renderer = TraceRenderer(clock: clock, hopDuration: hopDuration, mode: mode)
            renderer.drawTraces(traces, in: &context, projection: projection)
            renderer.drawNodes(nodes, in: &context, projection: projection)
            for trace in traces {
                guard let ms = latencyMillis[trace.id] else { continue }
                renderer.drawLatencyTooltip(trace, latencyMillis: ms, in: &context, projection: projection)
            }
        }
        .allowsHitTesting(false)
        .drawingGroup()
    }
}
#endif
