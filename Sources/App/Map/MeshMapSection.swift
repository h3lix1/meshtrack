// MeshMapSection — the headline map section, fully composed (SPEC §1, ADR 0007). It
// stacks the real MKMapView substrate (MeshMapView), the transparent animated trace
// overlay (TraceOverlayCanvas), and the floating viz-settings panel (VizSettingsPanel),
// driving the animation from a TimelineView(.animation) clock and the configurable
// VizSettings. This is the entry point the lead wires into the AppShell's network
// section for the live app.
//
// Snapshot/CI keeps using the self-contained Canvas map (DashboardView, live:false);
// this section is the MapKit substrate verified live.

#if canImport(MapKit) && os(macOS)
    import Domain
    import Persistence
    import SwiftUI

    public struct MeshMapSection: View {
        public let nodes: [NetworkNode]
        public let traces: [PacketTrace]
        /// Receive→publish latency (ms) per packet id, surfaced as edge tooltips.
        public let latencyMillis: [UInt32: Int]
        /// Worst-case relay-byte candidate count, for the confidence hint.
        public let relayCandidateCount: Int
        /// Channel presets live nodes have been seen on, for the filter menu (Task 4).
        public let availablePresets: [ChannelPreset]
        /// Store backing the tap-to-open node-detail popover (Task 5/6). When nil the
        /// markers aren't tappable (e.g. preview/snapshot composition).
        public let store: MeshStore?

        private let settings: VizSettings
        @State private var mapState = MeshMapState()
        @State private var channelFilter = ChannelFilter()
        @State private var selectedNode: NetworkNode?
        /// The packet id currently isolated on the map (nil = show all packets).
        @State private var selectedPacketID: UInt32?

        public init(
            nodes: [NetworkNode],
            traces: [PacketTrace],
            settings: VizSettings,
            latencyMillis: [UInt32: Int] = [:],
            relayCandidateCount: Int = 1,
            availablePresets: [ChannelPreset] = [],
            store: MeshStore? = nil
        ) {
            self.nodes = nodes
            self.traces = traces
            self.settings = settings
            self.latencyMillis = latencyMillis
            self.relayCandidateCount = relayCandidateCount
            self.availablePresets = availablePresets
            self.store = store
        }

        /// The channel/focus-narrowed collections the body needs, derived ONCE from the
        /// current inputs (nodes, traces, channel selection, packet focus). None of these
        /// depend on the animation clock, so computing them here — and capturing the
        /// results into the per-frame `TimelineView` closure — keeps the filtering off the
        /// 60 Hz redraw path. The previous computed properties recomputed `channelFilter`
        /// (an O(n) `Set` build + filter) two-to-three times PER FRAME.
        private struct DerivedView {
            let visibleNodes: [NetworkNode]
            let visibleTraces: [PacketTrace]
            /// Traces under the channel filter but BEFORE the packet focus — the legend
            /// lists these so a focused view still offers every packet to switch/reset to.
            let channelledTraces: [PacketTrace]
        }

        private var derived: DerivedView {
            let channelledNodes = channelFilter.nodes(nodes)
            let channelledTraces = channelFilter.traces(traces, nodes: nodes)
            let visibleNodes = PacketFocus.focusNodes(
                channelledNodes, traces: channelledTraces, selectedPacketID: selectedPacketID
            )
            return DerivedView(
                visibleNodes: visibleNodes,
                visibleTraces: PacketFocus.focusTraces(channelledTraces, selectedPacketID: selectedPacketID),
                channelledTraces: channelledTraces
            )
        }

        public var body: some View {
            // Derive the narrowed collections ONCE per state change. `body` re-runs only
            // when an observed input changes (nodes/traces/filter/focus) — the per-frame
            // clock lives inside the TimelineView closure below, which now just reads these
            // precomputed values instead of re-filtering every frame.
            let derived = derived
            return ZStack(alignment: .topTrailing) {
                // The MapKit substrate updates only when the node set changes — it stays
                // OUTSIDE the TimelineView so it isn't re-created every animation frame
                // (which spun updateNSView → state mutation → a view-graph beachball).
                MeshMapView(
                    nodes: derived.visibleNodes,
                    state: mapState,
                    onSelectNode: store == nil ? nil : { id in
                        selectedNode = derived.visibleNodes.first { $0.id == id }
                    }
                )

                // Only the animated trace overlay needs the per-frame clock.
                TimelineView(.animation) { timeline in
                    TraceOverlayCanvas(
                        nodes: derived.visibleNodes,
                        traces: derived.visibleTraces,
                        state: mapState,
                        clock: timeline.date.timeIntervalSinceReferenceDate,
                        hopDuration: settings.hopDuration,
                        mode: settings.mode,
                        latencyMillis: latencyMillis,
                        focusedPacketID: selectedPacketID,
                        showAllReceivers: settings.showAllReceivers
                    )
                }
                .allowsHitTesting(false)

                VStack(alignment: .trailing, spacing: 12) {
                    ChannelFilterControl(filter: channelFilter, presets: availablePresets)
                    VizSettingsPanel(
                        settings: settings,
                        traces: derived.channelledTraces,
                        relayCandidateCount: relayCandidateCount,
                        selectedPacketID: selectedPacketID,
                        onSelectPacket: {
                            selectedPacketID = PacketFocus.toggled($0, current: selectedPacketID)
                        }
                    )
                }
                .padding(16)
            }
            .popover(item: $selectedNode) { node in
                if let store {
                    NodeDetailPopover(node: node, store: store)
                }
            }
        }
    }

    #Preview("Mesh map section — sequential") {
        MeshMapSection(
            nodes: SampleNetwork.nodes,
            traces: SampleNetwork.traces,
            settings: VizSettings(hopDuration: 1.2, equaliseFinish: false),
            latencyMillis: [0x2A3B_4C5D: 182, 0x7788_99AA: 96],
            relayCandidateCount: 3
        )
        .frame(width: 900, height: 640)
    }

    #Preview("Mesh map section — equalise finish") {
        MeshMapSection(
            nodes: SampleNetwork.nodes,
            traces: SampleNetwork.traces,
            settings: VizSettings(hopDuration: 2.0, equaliseFinish: true),
            relayCandidateCount: 1
        )
        .frame(width: 900, height: 640)
    }

    #Preview("Viz settings panel") {
        VizSettingsPanel(
            settings: VizSettings(hopDuration: 1.5, equaliseFinish: true),
            traces: SampleNetwork.traces,
            relayCandidateCount: 4
        )
        .padding()
        .background(Color.black)
    }
#endif
