// MeshtrackApp — the runnable macOS SwiftUI app (the viewer/controller over the
// shared store, SPEC §3). Launches the RootView shell with the live, animating
// network visualization. Sample data drives it until the live store/MQTT feed is
// wired in the composition root.
//
//   swift run MeshtrackApp

import App
import SwiftUI

@main
struct MeshtrackApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
