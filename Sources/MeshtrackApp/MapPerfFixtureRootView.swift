// MapPerfFixtureRootView — launch-only Network map workload for xctrace.

import App
import SwiftUI

struct MapPerfFixtureRootView: View {
    let data: MapPerfData

    var body: some View {
        #if canImport(MapKit) && os(macOS)
            MeshMapSection(
                nodes: data.nodes,
                traces: data.traces,
                settings: VizSettings(hopDuration: 1.2, equaliseFinish: false),
                latencyMillis: data.latencyMillis,
                relayCandidateCount: 8,
                availablePresets: ChannelPreset.allCases,
                store: nil
            )
            .frame(minWidth: 1100, minHeight: 720)
            .preferredColorScheme(.dark)
        #else
            DashboardView(nodes: data.nodes, traces: data.traces, clock: 1.6)
        #endif
    }
}
