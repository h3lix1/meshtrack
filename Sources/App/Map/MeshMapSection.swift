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

        /// Nodes visible after the channel filter then the packet focus narrow it: the
        /// channel filter runs first, the focus (if any) isolates a single packet's
        /// trace + the nodes it touches.
        private var visibleNodes: [NetworkNode] {
            let channelled = channelFilter.nodes(nodes)
            return PacketFocus.focusNodes(
                channelled, traces: channelFilter.traces(traces, nodes: nodes),
                selectedPacketID: selectedPacketID
            )
        }

        private var visibleTraces: [PacketTrace] {
            PacketFocus.focusTraces(channelledTraces, selectedPacketID: selectedPacketID)
        }

        /// Traces under the channel filter but BEFORE the packet focus — the legend
        /// lists these so a focused view still offers every packet to switch/reset to.
        private var channelledTraces: [PacketTrace] {
            channelFilter.traces(traces, nodes: nodes)
        }

        public var body: some View {
            ZStack(alignment: .topTrailing) {
                // The MapKit substrate updates only when the node set changes — it stays
                // OUTSIDE the TimelineView so it isn't re-created every animation frame
                // (which spun updateNSView → state mutation → a view-graph beachball).
                MeshMapView(
                    nodes: visibleNodes,
                    state: mapState,
                    onSelectNode: store == nil ? nil : { selectedNode = nodeByID($0) }
                )

                // Only the animated trace overlay needs the per-frame clock.
                TimelineView(.animation) { timeline in
                    TraceOverlayCanvas(
                        nodes: visibleNodes,
                        traces: visibleTraces,
                        state: mapState,
                        clock: timeline.date.timeIntervalSinceReferenceDate,
                        hopDuration: settings.hopDuration,
                        mode: settings.mode,
                        latencyMillis: latencyMillis
                    )
                }
                .allowsHitTesting(false)

                VStack(alignment: .trailing, spacing: 12) {
                    ChannelFilterControl(filter: channelFilter, presets: availablePresets)
                    VizSettingsPanel(
                        settings: settings,
                        traces: channelledTraces,
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

        /// Resolve a tapped node id back to its NetworkNode (from the visible set).
        private func nodeByID(_ id: Int64) -> NetworkNode? {
            visibleNodes.first { $0.id == id }
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
