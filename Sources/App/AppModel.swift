// AppModel — the app's view-model registry (Phase 7 seam).
//
// A single `@MainActor @Observable` environment object that holds the per-section
// state and resolves each `AppSection` to its content view. `RootView` renders
// whatever the registry returns, so feature streams add a section by registering a
// provider from their OWN file (`appModel.register(.section) { … }`) — they never
// edit the `RootView` switch or `AppShell.swift` again.
//
// The default registry reproduces the existing sample-fed sections, so both the
// live app and the snapshot harness keep rendering every section deterministically.

import Persistence
import SwiftUI

/// Builds the content view for one `AppSection`. `@MainActor` because every
/// section view is a SwiftUI view backed by a main-actor view model.
public typealias SectionProvider = @MainActor () -> AnyView

@MainActor
@Observable
public final class AppModel {
    /// Positioned nodes for the Network/Nodes sections (sample or live).
    public var nodes: [NetworkNode]
    /// Animated packet traces for the Network section.
    public var traces: [PacketTrace]
    /// Whether the Network section animates a live `MKMapView`-style screen
    /// (`true`) or renders the deterministic Canvas-only map (`false`, snapshots).
    public var live: Bool

    /// The section currently selected in the shell, mirrored from `RootView` so the
    /// live shell can show section-specific chrome (e.g. the VCR replay bar belongs to
    /// the Network map only — item 2). Defaults to `.network`.
    public var currentSection: AppSection = .network

    /// Cross-section navigation hook (Finding 19). Set by `AppShell`/`RootView` to
    /// update the selected section, so section views (e.g. the node directory's
    /// "Open analytics" / "Apply config" actions) can route the operator to another
    /// section instead of doing nothing. `nil` until the shell wires it.
    @ObservationIgnored public var onNavigate: ((AppSection) -> Void)?

    /// Section → content-view provider. Resolved by `view(for:)`. Seeded with the
    /// built-in sections; feature streams override/extend via `register(_:_:)`.
    @ObservationIgnored private var registry: [AppSection: SectionProvider] = [:]

    /// A fresh in-memory store backing the default Fleet section so it renders the
    /// real `FleetConfigConsole` engine (empty/seeded) instead of fabricated rows —
    /// even in sample / first-run mode where no live store has been wired. Built once
    /// per model so the section keeps a stable view model across re-renders.
    @ObservationIgnored private lazy var sampleFleetStore: MeshStore? =
        try? MeshStore(DatabaseConnection.inMemory())

    public init(
        nodes: [NetworkNode] = SampleNetwork.nodes,
        traces: [PacketTrace] = SampleNetwork.traces,
        live: Bool = true
    ) {
        self.nodes = nodes
        self.traces = traces
        self.live = live
        registerDefaults()
    }

    /// Register (or replace) the content provider for `section`. Feature streams
    /// call this from their own composition file — no edit to `RootView`.
    public func register(_ section: AppSection, _ provider: @escaping SectionProvider) {
        registry[section] = provider
    }

    /// The content view for `section`. Falls back to a placeholder when nothing is
    /// registered (so an in-flight, not-yet-wired section never crashes the shell).
    @ViewBuilder
    public func view(for section: AppSection) -> some View {
        if let provider = registry[section] {
            provider()
        } else {
            UnregisteredSectionView(section: section)
        }
    }

    /// Whether a content provider is registered for `section` (testing seam — the
    /// shell renders a placeholder for unregistered sections).
    func isRegistered(_ section: AppSection) -> Bool {
        registry[section] != nil
    }

    // MARK: Default registry (sample-fed; mirrors the pre-registry RootView)

    private func registerDefaults() {
        register(.network) { [self] in
            AnyView(NetworkSectionView(nodes: nodes, traces: traces, live: live))
        }
        register(.nodes) { [self] in AnyView(NodesView(nodes: nodes)) }
        register(.packets) { AnyView(PacketsView(packets: SampleNetwork.packets)) }
        register(.telemetry) { AnyView(TelemetryChartView(series: SampleNetwork.telemetry)) }
        register(.analytics) {
            AnyView(SectionMessageView(
                title: "Analytics",
                message: "Connect a live feed to see per-node SNR, hops, peers and heatmaps."
            ))
        }
        // Mesh-traffic analytics (Phase 10): sample-seeded VMs for snapshot / first-run;
        // the live shell overrides these with store-backed, packet-fed VMs.
        register(.ports) { AnyView(PortStatsSection(viewModel: PortStatsViewModel.sample())) }
        register(.offenders) { AnyView(OffendersSection(viewModel: OffendersViewModel.sample())) }
        register(.alerts) { AnyView(AlertsView(alerts: SampleNetwork.alerts)) }
        register(.messages) {
            AnyView(SectionMessageView(
                title: "Messages",
                message: "Connect a broker to see decoded channel messages (monitor-only)."
            ))
        }
        register(.health) { AnyView(ObservabilityView(metrics: SampleNetwork.metrics)) }
        // Fleet shows the REAL engine everywhere — never the SF-Gate demo. Without a
        // live store (sample / first-run), back the console with a fresh in-memory
        // store so it renders the genuine empty/seeded engine UI (templates editor +
        // node targeting + rollout) rather than fabricated rows.
        register(.fleet) { [self] in
            if let store = sampleFleetStore {
                AnyView(FleetConfigConsole(viewModel: FleetConfigViewModel(store: store)))
            } else {
                AnyView(SectionMessageView(
                    title: "Fleet Configuration",
                    message: "Fleet configuration is unavailable — the local store could not be opened."
                ))
            }
        }
        // Provision shows the REAL guided workflow everywhere. Without a live store
        // (sample / first-run), back it with the same fresh in-memory store so the
        // render→diff→confirm→apply→verify flow is exercisable end-to-end (over a
        // StoreBackedAdminChannel) rather than left unreachable.
        register(.provision) { [self] in
            if let store = sampleFleetStore {
                AnyView(ProvisioningWorkflowView(
                    viewModel: ProvisioningWorkflowFactory.make(store: store, draft: .init(), channelFor: nil)
                ))
            } else {
                AnyView(SectionMessageView(
                    title: "Provision",
                    message: "Provisioning is unavailable — the local store could not be opened."
                ))
            }
        }
    }
}

/// The Network section: the live animating screen, or the deterministic Canvas-only
/// map for snapshots (`live: false`, ADR 0007).
struct NetworkSectionView: View {
    let nodes: [NetworkNode]
    let traces: [PacketTrace]
    let live: Bool

    var body: some View {
        if live {
            LiveNetworkScreen(nodes: nodes, traces: traces)
        } else {
            DashboardView(nodes: nodes, traces: traces, clock: 1.6)
        }
    }
}

/// Placeholder for a section with no registered provider yet.
struct UnregisteredSectionView: View {
    let section: AppSection

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer").font(.largeTitle).foregroundStyle(.secondary)
            Text("\(section.title) — coming soon").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }
}
