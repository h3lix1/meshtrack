// MeshtrackApp — the runnable macOS SwiftUI app (the viewer/controller, SPEC §3).
//
// Composition root: if a broker is configured in the environment it goes LIVE
// (in-app MQTT ingest → the animating network visualization); otherwise it shows
// sample data. The live wiring lives in `LiveCoordinator` (this executable) so the
// `App` library stays snapshot-pure (phase7-gui §4).
//
//   swift run MeshtrackApp
//   live: MESHTRACK_MQTT_HOST=mqtt.bayme.sh MESHTRACK_MQTT_USER=… \
//         MESHTRACK_MQTT_PASS=… MESHTRACK_MQTT_TLS=1 \
//         MESHTRACK_MQTT_TOPIC=msh/US/bayarea/2/e/# swift run MeshtrackApp

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

    /// Live shell when a broker is configured; the sample-fed shell otherwise.
    @ViewBuilder private var content: some View {
        if let coordinator {
            LiveRootView(coordinator: coordinator)
        } else {
            RootView(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces)
        }
    }

    /// Build + start the live coordinator iff a broker host is in the environment.
    /// Any failure (e.g. opening the store) silently leaves the app on sample data.
    @MainActor private func goLiveIfConfigured() {
        guard coordinator == nil, let settings = LiveBrokerSettings.fromEnvironment(),
              let live = try? LiveCoordinator(settings: settings) else { return }
        live.start()
        coordinator = live
    }
}

/// The live shell: feeds the coordinator's `@Observable` view model into an
/// `AppModel` (the section registry), so every section renders live data and the
/// Network section animates real traffic. Until the first node reports a position
/// it overlays a "connecting…" affordance; once nodes arrive the map takes over.
struct LiveRootView: View {
    let coordinator: LiveCoordinator
    @State private var model = AppModel(nodes: [], traces: [], live: true)

    var body: some View {
        ZStack {
            RootView(model: model)
            if coordinator.viewModel.nodes.isEmpty {
                ConnectingOverlay(host: coordinator.brokerHost)
            }
        }
        // Mirror the live view model into the AppModel registry. Reading the
        // @Observable nodes/traces here re-runs this body as packets arrive, and
        // re-seeding the model rebuilds its section providers over the new data.
        .onChange(of: coordinator.viewModel.nodes) { _, nodes in
            model.nodes = nodes
        }
        .onChange(of: coordinator.viewModel.traces) { _, traces in
            model.traces = traces
        }
    }
}

/// "Connecting…" affordance shown until the first positioned node arrives. Shows
/// only the broker host — never credentials.
struct ConnectingOverlay: View {
    let host: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.cyan)
            Text("Connecting to \(host)…").font(.headline).foregroundStyle(.white)
            Text("Waiting for nodes to report a position")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
