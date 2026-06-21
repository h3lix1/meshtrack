// AppComposition — the lead's integration seam: wires every AppSection to its live,
// store-backed Phase 7 view. Called from the MeshtrackApp composition root with the
// shared store + clock, so the App library itself stays composition-root-free
// (it imports Domain/Persistence/RuleEngine/Provisioning only). Sections that
// self-load do so via their own `.task`; the few that don't are wrapped here.

import Domain
import Persistence
import SwiftUI

public extension AppModel {
    /// Register every section to its store-backed bespoke view. The Network section
    /// uses the real MapKit substrate (G1, ADR 0007) when MapKit is available, else
    /// the deterministic Canvas map already registered by default.
    @MainActor
    func registerLiveSections(store: MeshStore, clock: any Domain.Clock) {
        let viz = VizSettings()

        #if canImport(MapKit) && os(macOS)
            register(.network) { [self] in
                AnyView(MeshMapSection(nodes: nodes, traces: traces, settings: viz))
            }
        #endif

        register(.nodes) {
            AnyView(NodeDirectoryView(viewModel: NodeDirectoryViewModel(store: store)))
        }
        register(.packets) {
            AnyView(PacketInspectorSection(viewModel: PacketInspectorSample.viewModel()))
        }
        register(.telemetry) {
            AnyView(PerNodeSectionView(store: store, title: "Telemetry") { nodeNum in
                TelemetryChartsView(viewModel: TelemetryChartsViewModel(store: store, nodeNum: nodeNum))
            })
        }
        register(.analytics) {
            AnyView(PerNodeSectionView(store: store, title: "Analytics") { nodeNum in
                NodeAnalyticsView(viewModel: NodeAnalyticsViewModel(store: store, nodeNum: nodeNum))
            })
        }
        register(.alerts) {
            AnyView(AlertsSectionView(store: store, clock: clock))
        }
        register(.messages) {
            AnyView(ChannelsView(viewModel: ChannelsViewModel(store: store)))
        }
        register(.health) {
            AnyView(CollisionMatrixView(viewModel: CollisionMatrixViewModel(store: store)))
        }
        register(.fleet) {
            AnyView(FleetConfigConsole(viewModel: FleetConfigViewModel(store: store)))
        }
    }
}

/// Resolves a per-node section by picking the first node the store knows about.
/// Telemetry and analytics are per-node; a richer node picker is a follow-up.
struct PerNodeSectionView<Content: View>: View {
    let store: MeshStore
    let title: String
    @ViewBuilder let content: (Int64) -> Content

    @State private var nodeNum: Int64?
    @State private var loaded = false

    var body: some View {
        Group {
            if let nodeNum {
                content(nodeNum).id(nodeNum)
            } else {
                SectionMessageView(
                    title: title,
                    message: loaded ? "No nodes with data yet." : "Loading…"
                )
            }
        }
        .task {
            let nodes = await (try? store.allNodes()) ?? []
            nodeNum = nodes.first?.node_num
            loaded = true
        }
    }
}

/// Bridges the alerts + arming view models into the array-driven `AlertsConsoleView`,
/// loading both on appear.
struct AlertsSectionView: View {
    @State private var alerts: AlertsConsoleViewModel
    @State private var arming: ArmingFlowViewModel

    init(store: MeshStore, clock: any Domain.Clock) {
        _alerts = State(initialValue: AlertsConsoleViewModel(store: store, clock: clock))
        _arming = State(initialValue: ArmingFlowViewModel(store: store, clock: clock))
    }

    var body: some View {
        AlertsConsoleView(
            firing: alerts.firing,
            acknowledged: alerts.acknowledged,
            resolved: alerts.resolved,
            suppressed: alerts.suppressedNodes,
            arming: arming.rows,
            onAcknowledge: { item in Task { try? await alerts.acknowledge(item) } },
            onSnooze: { item in Task { try? await alerts.snooze(item, forSeconds: 3600) } },
            onResolve: { item in Task { try? await alerts.resolve(item) } }
        )
        .task {
            try? await alerts.load()
            try? await arming.load()
        }
    }
}

/// A simple dark-theme placeholder/empty state for sections awaiting data.
struct SectionMessageView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title.bold()).foregroundStyle(.white)
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }
}
