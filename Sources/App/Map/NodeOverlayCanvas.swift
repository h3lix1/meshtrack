// NodeOverlayCanvas — the transparent SwiftUI Canvas that draws the *static* node
// glows + text labels on top of the live MKMapView (ADR 0007), split out from the
// per-frame trace overlay (TraceOverlayCanvas) for performance.
//
// Node glows/labels DON'T change between trace-animation frames — only when the map
// camera moves (pan/zoom) or the node set changes. Because this Canvas is NOT driven
// by a TimelineView clock, SwiftUI only re-evaluates it when its inputs change: the
// `nodes` array, or the observed `MeshMapState` (`regionRevision` bumped on every
// camera move, `projection` refreshed alongside it). That removes hundreds of blurred
// glows + resolved text labels from the trace-animation redraw path — the main CPU cost.
//
// It reads the shared MapProjection from MeshMapState (refreshed on every camera move)
// and paints through the shared TraceRenderer with neutral animation params (the node
// drawing is clock-independent). `allowsHitTesting(false)` lets pan/zoom fall through
// to the map underneath.

#if canImport(MapKit) && os(macOS)
    import Domain
    import SwiftUI

    public struct NodeOverlayCanvas: View {
        public let nodes: [NetworkNode]
        public let state: MeshMapState

        public init(nodes: [NetworkNode], state: MeshMapState) {
            self.nodes = nodes
            self.state = state
        }

        public var body: some View {
            Canvas { context, size in
                // Reading regionRevision inside the Canvas closure makes the overlay
                // re-render whenever the map's camera moves. With no TimelineView clock,
                // this and `nodes` are the only things that trigger a redraw.
                _ = state.regionRevision
                guard let projection = state.projection else { return }
                let cachedProjection = CachedTraceProjection(base: projection)
                let detail = MapDeclutterPolicy.traceDetail(
                    isInteracting: state.isInteracting,
                    declutterLevel: state.declutterLevel
                )
                // Draw node glows + labels only at full detail (skipped during pan/zoom),
                // matching the gating the per-frame overlay previously used for nodes.
                guard detail == .full else { return }
                // Nodes don't depend on the trace animation clock — construct the
                // renderer with neutral animation params.
                let renderer = TraceRenderer(
                    clock: 0, hopDuration: 1, mode: .sequential, detail: detail
                )
                MapPerfSignpost.interval("map.nodes.draw") {
                    renderer.drawNodes(
                        nodes,
                        in: &context,
                        projection: cachedProjection,
                        cullingBounds: CGRect(origin: .zero, size: size)
                    )
                }
            }
            .allowsHitTesting(false)
            .drawingGroup()
        }
    }
#endif
