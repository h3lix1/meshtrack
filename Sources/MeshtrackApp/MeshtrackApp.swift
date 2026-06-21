// MeshtrackApp — the runnable macOS SwiftUI app (the viewer/controller, SPEC §3).
// If a broker is configured in the environment it goes LIVE (in-app MQTT ingest →
// the animating network visualization); otherwise it shows sample data.
//
//   swift run MeshtrackApp
//   live: MESHTRACK_MQTT_HOST=mqtt.bayme.sh MESHTRACK_MQTT_USER=… \
//         MESHTRACK_MQTT_PASS=… MESHTRACK_MQTT_TOPIC=msh/US/bayarea/2/e/# swift run MeshtrackApp

import App
import SwiftUI

@main
struct MeshtrackApp: App {
    @State private var coordinator: LiveCoordinator?

    var body: some Scene {
        WindowGroup {
            content
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .task { goLiveIfConfigured() }
        }
        .windowStyle(.hiddenTitleBar)
    }

    @ViewBuilder private var content: some View {
        if let coordinator {
            LiveRootView(coordinator: coordinator)
        } else {
            RootView(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces)
        }
    }

    @MainActor private func goLiveIfConfigured() {
        guard coordinator == nil, let config = LiveCoordinator.environmentConfig(),
              let live = try? LiveCoordinator(config: config) else { return }
        live.start()
        coordinator = live
    }
}
