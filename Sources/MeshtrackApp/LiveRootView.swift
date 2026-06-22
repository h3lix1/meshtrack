// LiveRootView — the live shell, split out of MeshtrackApp.swift so that file stays
// within the lint length cap. Feeds the coordinator's @Observable view model into an
// AppModel (the section registry) and overlays the live transport / palette / status.

import App
import Domain
import SwiftUI

/// The live shell: feeds the coordinator's `@Observable` view model into an
/// `AppModel` (the section registry), so every section renders live data and the
/// Network section animates real traffic. A connection-status badge overlays the
/// top-trailing corner (host only, never credentials).
struct LiveRootView: View {
    let coordinator: LiveCoordinator
    @State private var model: AppModel
    /// The ⌘K command palette over the live fleet (Finding 17). Store-backed so the
    /// corpus reflects real nodes/packets/channels; selecting a result routes to the
    /// matching section via `model.onNavigate`.
    @State private var search: SearchViewModel
    /// The live time-travel transport (Finding 17): loads the last 24h of real
    /// observations, and its `controlState` drives the VCR overlay.
    @State private var timeline: TimelineViewModel

    init(coordinator: LiveCoordinator) {
        self.coordinator = coordinator
        let model = AppModel(nodes: [], traces: [], live: true)
        // Wire every section to its live, store-backed view (the headline MapKit map,
        // node directory, telemetry, analytics, alerts, messages, health) — the
        // production OTA admin link so Fleet/Provision apply through the real
        // MeshAdminChannel rather than a same-DB echo (Finding 8; `LiveAdminLink` is
        // the single HIL seam) — and the live packet inspector (Finding 17).
        model.registerLiveSections(
            store: coordinator.store,
            clock: SystemWallClock(),
            adminLink: LiveAdminLink(),
            packetInspector: coordinator.packetInspector,
            portStats: coordinator.portStats,
            offenders: coordinator.offenders
        )
        _model = State(initialValue: model)
        _search = State(initialValue: SearchViewModel(store: coordinator.store))
        _timeline = State(initialValue: TimelineViewModel(store: coordinator.store, clock: SystemWallClock()))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RootView(model: model)
            if coordinator.viewModel.nodes.isEmpty {
                ConnectingOverlay(host: coordinator.brokerHost)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ConnectionStatusBadge(status: coordinator.status)
                .padding(16)
            // The time-travel transport bar, anchored bottom-centre over the shell.
            VCRControlView(
                state: timeline.controlState,
                actions: VCRControlActions(
                    togglePlay: { timeline.togglePlay() },
                    scrub: { timeline.scrub(toFraction: $0) },
                    setSpeed: { timeline.setSpeed($0) },
                    goLive: { timeline.goLive() }
                )
            )
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // The ⌘K palette layers over every section; selecting routes via onNavigate.
        .commandPalette(search)
        // Mirror the live view model into the AppModel registry — but ONLY while the
        // VCR is live. When the operator scrubs into the past (`timeline.isReviewing`),
        // the map must show the RECONSTRUCTED frame at the playhead, not the live feed
        // (Phase 10 item 1: the replay bar previously moved but the map stayed live).
        .onChange(of: coordinator.viewModel.nodes) { _, nodes in
            if !timeline.isReviewing { model.nodes = nodes }
        }
        .onChange(of: coordinator.viewModel.traces) { _, traces in
            if !timeline.isReviewing { model.traces = traces }
        }
        // Switch the map source as the playhead enters/leaves review.
        .onChange(of: timeline.isReviewing) { _, reviewing in
            if reviewing {
                model.nodes = timeline.nodes
                model.traces = timeline.traces
            } else {
                model.nodes = coordinator.viewModel.nodes
                model.traces = coordinator.viewModel.traces
            }
        }
        // While reviewing, keep feeding the reconstructed frame as the playhead moves.
        .onChange(of: timeline.traces) { _, traces in
            if timeline.isReviewing { model.traces = traces }
        }
        // Refresh the palette corpus from the store each time it opens.
        .onChange(of: search.isPresented) { _, presented in
            if presented { Task { try? await search.reloadCorpus() } }
        }
        // Route a selected search result to its section, then clear the target.
        .onChange(of: search.selectedTarget) { _, target in
            guard let target else { return }
            model.onNavigate?(Self.section(for: target))
            search.consumeTarget()
        }
        // Load the timeline's 24h observation window once the shell appears.
        .task { try? await timeline.load() }
    }

    /// Map a command-palette target to the section that surfaces it (Finding 17).
    private static func section(for target: SearchTarget) -> AppSection {
        switch target {
        case .node: .nodes
        case .packet: .packets
        case .channel: .messages
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
