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
        /// Kept for source-compatibility with the MeshMapSection call site, but no longer
        /// drawn here: the static node glows/labels now render in their own
        /// `NodeOverlayCanvas`, which redraws only on camera/node changes rather than on
        /// every trace-animation frame.
        public let nodes: [NetworkNode]
        public let traces: [PacketTrace]
        public let state: MeshMapState
        public var clock: Double
        public var hopDuration: Double
        public var mode: TraceTimingMode
        /// Optional receive→publish latency (ms) per packet id, surfaced as edge tooltips.
        public var latencyMillis: [UInt32: Int]
        /// The packet id focused in the legend — drives per-hop labels (item 3) and the
        /// all-receivers overlay (item 6). nil = no focus.
        public var focusedPacketID: UInt32?
        /// Whether to ring every node that received the focused packet (item 6).
        public var showAllReceivers: Bool

        public init(
            nodes: [NetworkNode],
            traces: [PacketTrace],
            state: MeshMapState,
            clock: Double,
            hopDuration: Double,
            mode: TraceTimingMode,
            latencyMillis: [UInt32: Int] = [:],
            focusedPacketID: UInt32? = nil,
            showAllReceivers: Bool = false
        ) {
            self.nodes = nodes
            self.traces = traces
            self.state = state
            self.clock = clock
            self.hopDuration = hopDuration
            self.mode = mode
            self.latencyMillis = latencyMillis
            self.focusedPacketID = focusedPacketID
            self.showAllReceivers = showAllReceivers
        }

        public var body: some View {
            Canvas { context, size in
                // Reading regionRevision inside the Canvas closure makes the overlay
                // re-render whenever the map's camera moves.
                _ = state.regionRevision
                guard let projection = state.projection else { return }
                let cachedProjection = CachedTraceProjection(base: projection)
                let detail = MapDeclutterPolicy.traceDetail(
                    isInteracting: state.isInteracting,
                    declutterLevel: state.declutterLevel
                )
                let renderer = TraceRenderer(
                    clock: clock, hopDuration: hopDuration, mode: mode,
                    focusedPacketID: focusedPacketID,
                    showAllReceivers: showAllReceivers,
                    detail: detail
                )
                let cullingBounds = CGRect(origin: .zero, size: size)
                MapPerfSignpost.interval("map.overlay.draw") {
                    // Nodes are now drawn by NodeOverlayCanvas (off the per-frame clock);
                    // this overlay paints only the moving traces + their latency tooltips.
                    renderer.drawTraces(
                        traces, in: &context, projection: cachedProjection, cullingBounds: cullingBounds
                    )
                    if detail == .full {
                        for trace in traces {
                            guard let latencyMs = latencyMillis[trace.id] else { continue }
                            renderer.drawLatencyTooltip(
                                trace,
                                latencyMillis: latencyMs,
                                in: &context,
                                projection: cachedProjection
                            )
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .drawingGroup()
        }
    }
#endif
