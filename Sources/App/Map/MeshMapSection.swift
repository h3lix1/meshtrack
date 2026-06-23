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
        /// Synthetic VCR/replay clock. nil uses the live animation clock.
        public let clockOverride: Double?
        /// Controlled packet focus from the live shell. nil with no callback means
        /// MeshMapSection owns focus locally (preview/default path).
        public let selectedPacketID: UInt32?
        /// Called when the operator focuses or clears a packet from the legend.
        public let onSelectPacket: ((UInt32?) -> Void)?
        /// Called when the operator changes how ambiguous relay-byte guesses are handled.
        public let onRelayGuessingPolicyChange: ((RelayGuessingPolicy) -> Void)?

        private let settings: VizSettings
        @State private var mapState = MeshMapState()
        @State private var channelFilter = ChannelFilter()
        @State private var selectedNode: NetworkNode?
        /// The packet id currently isolated on the map (nil = show all packets).
        @State private var localSelectedPacketID: UInt32?
        /// The last full trace for the focused packet, kept so live-window eviction does
        /// not make the focused legend row/path disappear before the operator clears it.
        @State private var pinnedPacketTrace: PacketTrace?

        public init(
            nodes: [NetworkNode],
            traces: [PacketTrace],
            settings: VizSettings,
            latencyMillis: [UInt32: Int] = [:],
            relayCandidateCount: Int = 1,
            availablePresets: [ChannelPreset] = [],
            store: MeshStore? = nil,
            clockOverride: Double? = nil,
            selectedPacketID: UInt32? = nil,
            onSelectPacket: ((UInt32?) -> Void)? = nil,
            onRelayGuessingPolicyChange: ((RelayGuessingPolicy) -> Void)? = nil
        ) {
            self.nodes = nodes
            self.traces = traces
            self.settings = settings
            self.latencyMillis = latencyMillis
            self.relayCandidateCount = relayCandidateCount
            self.availablePresets = availablePresets
            self.store = store
            self.clockOverride = clockOverride
            self.selectedPacketID = selectedPacketID
            self.onSelectPacket = onSelectPacket
            self.onRelayGuessingPolicyChange = onRelayGuessingPolicyChange
        }

        private var focusedPacketID: UInt32? {
            onSelectPacket == nil ? localSelectedPacketID : selectedPacketID
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
            let tracePool = PacketFocus.pinSelectedTrace(
                traces,
                selectedPacketID: focusedPacketID,
                pinnedTrace: pinnedPacketTrace
            )
            let channelledNodes = channelFilter.nodes(nodes)
            let channelledTraces = channelFilter.traces(tracePool, nodes: nodes)
            let visibleNodes = PacketFocus.focusNodes(
                channelledNodes, traces: channelledTraces, selectedPacketID: focusedPacketID
            )
            return DerivedView(
                visibleNodes: visibleNodes,
                visibleTraces: PacketFocus.focusTraces(channelledTraces, selectedPacketID: focusedPacketID),
                channelledTraces: channelledTraces
            )
        }

        public var body: some View {
            // Derive the narrowed collections ONCE per state change. `body` re-runs only
            // when an observed input changes (nodes/traces/filter/focus) — the per-frame
            // clock lives inside the TimelineView closure below, which now just reads these
            // precomputed values instead of re-filtering every frame.
            let derived = derived
            return GeometryReader { geometry in
                let panelMaxHeight = min(520, max(180, geometry.size.height - 84))
                ZStack(alignment: .topTrailing) {
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

                    // Static node glows/labels: their own Canvas, redrawn only when the
                    // camera (regionRevision) or the node set changes — NOT on the
                    // per-frame animation clock. This keeps hundreds of blurred glows +
                    // text labels off the trace-animation redraw path.
                    NodeOverlayCanvas(nodes: derived.visibleNodes, state: mapState)

                    // The animated trace overlay + floating controls are factored into
                    // helpers so this view-builder expression stays within the Swift
                    // type-checker's budget.
                    traceOverlay(derived)
                    controlsPanel(derived, panelMaxHeight: panelMaxHeight)
                }
            }
            .onChange(of: traces) { _, newTraces in
                refreshPinnedTrace(from: newTraces)
            }
            .onChange(of: selectedPacketID) { _, newSelection in
                guard onSelectPacket != nil else { return }
                refreshPinnedTrace(from: traces, selectedPacketID: newSelection)
            }
            .onChange(of: settings.relayGuessingPolicy) { _, _ in
                onRelayGuessingPolicyChange?(settings.relayGuessingPolicy)
            }
            .popover(item: $selectedNode) { node in
                if let store {
                    NodeDetailPopover(node: node, store: store)
                }
            }
        }

        /// The animated trace overlay, on its demand-driven schedule (idles when nothing
        /// is animating). Extracted from `body` to keep the view-builder expression within
        /// the Swift type-checker's budget.
        @ViewBuilder
        private func traceOverlay(_ derived: DerivedView) -> some View {
            TimelineView(traceAnimationSchedule(for: derived.visibleTraces)) { timeline in
                let renderClock = clockOverride ?? timeline.date.timeIntervalSinceReferenceDate
                TraceOverlayCanvas(
                    nodes: derived.visibleNodes,
                    traces: derived.visibleTraces,
                    state: mapState,
                    clock: renderClock,
                    hopDuration: settings.hopDuration,
                    mode: settings.mode,
                    latencyMillis: latencyMillis,
                    focusedPacketID: focusedPacketID,
                    showAllReceivers: settings.showAllReceivers
                )
            }
            .allowsHitTesting(false)
        }

        /// The floating channel-filter + viz-settings panel, extracted from `body` for the
        /// same type-checker reason.
        @ViewBuilder
        private func controlsPanel(_ derived: DerivedView, panelMaxHeight: CGFloat) -> some View {
            VStack(alignment: .trailing, spacing: 12) {
                ChannelFilterControl(filter: channelFilter, presets: availablePresets)
                VizSettingsPanel(
                    settings: settings,
                    traces: derived.channelledTraces,
                    relayCandidateCount: relayCandidateCount,
                    selectedPacketID: focusedPacketID,
                    maxHeight: panelMaxHeight,
                    onSelectPacket: { packetID in
                        togglePacketFocus(packetID, availableTraces: derived.channelledTraces)
                    }
                )
            }
            .padding(16)
        }

        /// The demand-driven animation schedule for the trace overlay: it repaints only
        /// while a trace is still drawing, then idles — instead of the stock `.animation`
        /// schedule's continuous full-refresh-rate repaints that pinned a CPU at 100%.
        /// During replay the clock is supplied externally (`clockOverride`), so the
        /// schedule is paused and parent re-renders (a new `clockOverride`) drive redraws.
        private func traceAnimationSchedule(for traces: [PacketTrace]) -> TraceAnimationSchedule {
            guard clockOverride == nil else { return .paused }
            return TraceAnimationSchedule(
                horizon: TraceAnimationSchedule.horizon(
                    for: traces, hopDuration: settings.hopDuration, mode: settings.mode
                )
            )
        }

        private func togglePacketFocus(_ packetID: UInt32, availableTraces: [PacketTrace]) {
            let next = PacketFocus.toggled(packetID, current: focusedPacketID)
            if let onSelectPacket {
                onSelectPacket(next)
            } else {
                localSelectedPacketID = next
            }
            refreshPinnedTrace(from: availableTraces, selectedPacketID: next)
        }

        private func refreshPinnedTrace(
            from availableTraces: [PacketTrace],
            selectedPacketID: UInt32? = nil
        ) {
            guard let selectedPacketID = selectedPacketID ?? focusedPacketID else {
                pinnedPacketTrace = nil
                return
            }
            if let current = availableTraces.first(where: { $0.id == selectedPacketID }) {
                pinnedPacketTrace = current
            } else if pinnedPacketTrace?.id != selectedPacketID {
                pinnedPacketTrace = nil
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
