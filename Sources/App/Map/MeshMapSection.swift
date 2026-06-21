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
import SwiftUI

public struct MeshMapSection: View {
    public let nodes: [NetworkNode]
    public let traces: [PacketTrace]
    /// Receive→publish latency (ms) per packet id, surfaced as edge tooltips.
    public let latencyMillis: [UInt32: Int]
    /// Worst-case relay-byte candidate count, for the confidence hint.
    public let relayCandidateCount: Int

    private let settings: VizSettings
    @State private var mapState = MeshMapState()

    public init(
        nodes: [NetworkNode],
        traces: [PacketTrace],
        settings: VizSettings,
        latencyMillis: [UInt32: Int] = [:],
        relayCandidateCount: Int = 1
    ) {
        self.nodes = nodes
        self.traces = traces
        self.settings = settings
        self.latencyMillis = latencyMillis
        self.relayCandidateCount = relayCandidateCount
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let clock = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topTrailing) {
                MeshMapView(nodes: nodes, state: mapState)
                TraceOverlayCanvas(
                    nodes: nodes,
                    traces: traces,
                    state: mapState,
                    clock: clock,
                    hopDuration: settings.hopDuration,
                    mode: settings.mode,
                    latencyMillis: latencyMillis
                )
                VizSettingsPanel(
                    settings: settings,
                    traces: traces,
                    relayCandidateCount: relayCandidateCount
                )
                .padding(16)
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
