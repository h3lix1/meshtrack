// AppComposition — the lead's integration seam: wires every AppSection to its live,
// store-backed Phase 7 view. Called from the MeshtrackApp composition root with the
// shared store + clock, so the App library itself stays composition-root-free
// (it imports Domain/Persistence/RuleEngine/Provisioning only). Sections that
// self-load do so via their own `.task`; the few that don't are wrapped here.

import Domain
import Persistence
import Provisioning
import SwiftUI

public extension AppModel {
    /// Register every section to its store-backed bespoke view. The Network section
    /// uses the real MapKit substrate (G1, ADR 0007) when MapKit is available, else
    /// the deterministic Canvas map already registered by default.
    ///
    /// `adminLink` is the production over-the-air admin primitive (Finding 8). When
    /// provided, the Fleet + Provision sections apply through the real OTA path
    /// (`MeshAdminChannel` → `LiveAdminTransport`) instead of the same-DB
    /// `StoreBackedAdminChannel` echo. `nil` keeps the store-backed default (sample /
    /// snapshot / first-run, where there is no radio).
    ///
    /// `packetInspector` is the live, coordinator-fed packet inspector (Finding 17).
    /// When provided, the `.packets` section renders real decoded traffic (instead of
    /// `PacketInspectorSample`) and its `latencyMillis` feeds the map's latency overlay.
    @MainActor
    func registerLiveSections(
        store: MeshStore,
        clock: any Domain.Clock,
        adminLink: (any AdminLink)? = nil,
        packetInspector: PacketInspectorViewModel? = nil,
        portStats: PortStatsViewModel? = nil,
        offenders: OffendersViewModel? = nil,
        onRelayGuessingChange: ((RelayGuessingPolicy) -> Void)? = nil
    ) {
        let viz = VizSettings()
        // The production OTA channel factory over the live admin link (Finding 8). The
        // closures replace the store-backed `channelFor` defaults so an apply SENDS
        // real begin → set… → commit admin messages and verifies by reading config
        // back — no more same-DB echo. `nil` when no radio link is wired.
        let otaFactory = adminLink.map { OTAAdminChannelFactory(link: $0) }

        #if canImport(MapKit) && os(macOS)
            register(.network) { [self] in
                // Channel-filter options derived from the presets live nodes have been
                // seen on; `store` makes the markers tappable (node detail + More Details).
                let presets = Array(Set(nodes.compactMap(\.preset))).sorted { $0.rawValue < $1.rawValue }
                return AnyView(MeshMapSection(
                    nodes: nodes,
                    traces: traces,
                    settings: viz,
                    // Live receive→publish latency per packet from the inspector feeds
                    // the map's latency overlay (Finding 17).
                    latencyMillis: packetInspector?.latencyMillis ?? [:],
                    availablePresets: presets,
                    store: store,
                    clockOverride: replayClock,
                    selectedPacketID: focusedPacketID,
                    onSelectPacket: { [self] packetID in
                        focusedPacketID = packetID
                        onPacketFocusChange?(packetID)
                    },
                    onRelayGuessingPolicyChange: onRelayGuessingChange
                ))
            }
        #endif

        registerNodesSection(store: store, otaFactory: otaFactory)
        register(.packets) {
            // Live decoded traffic when wired; sample data only when there's no
            // coordinator (snapshot / first-run) (Finding 17).
            AnyView(PacketInspectorSection(
                viewModel: packetInspector ?? PacketInspectorSample.viewModel()
            ))
        }
        // Telemetry + Analytics are per-node; the node PICKER (Phase 10) lets the
        // operator choose any node — no longer pinned to `allNodes().first`, which is
        // usually a transient passer-by with no retained data (items 7/8).
        register(.telemetry) {
            AnyView(NodeDataSectionView(store: store, title: "Telemetry") { nodeNum in
                TelemetryChartsView(viewModel: TelemetryChartsViewModel(store: store, nodeNum: nodeNum))
            })
        }
        register(.analytics) {
            AnyView(NodeDataSectionView(store: store, title: "Analytics") { nodeNum in
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
        registerTrafficSections(store: store, portStats: portStats, offenders: offenders)
        registerProvisioningSections(store: store, otaFactory: otaFactory)
    }

    /// Mesh-traffic analytics sections (Phase 10, items 11–13): Port Numbers + Largest
    /// Offenders. Split out of `registerLiveSections` (lint body-length cap). The live
    /// VMs are fed the decoded-packet stream by `LiveCoordinator` and passed in here so
    /// the UI shows the SAME running aggregates; when absent (e.g. `AppModelTests`) a
    /// store-backed VM is constructed so the sections still register.
    @MainActor
    private func registerTrafficSections(
        store: MeshStore,
        portStats: PortStatsViewModel?,
        offenders: OffendersViewModel?
    ) {
        let portsVM = portStats ?? PortStatsViewModel(store: store)
        let offendersVM = offenders ?? OffendersViewModel(store: store)
        register(.ports) { AnyView(PortStatsSection(viewModel: portsVM)) }
        register(.offenders) { AnyView(OffendersSection(viewModel: offendersVM)) }
    }

    /// The node-directory section. Split out of `registerLiveSections` (lint
    /// body-length cap). Its actions route to real sections (Finding 19) and, new in
    /// Phase 10, the Favorite ☆ / Ignore actions send an imperative admin command over
    /// the real OTA link — a no-op when no radio is wired (sample / snapshot / first-run).
    @MainActor
    private func registerNodesSection(store: MeshStore, otaFactory: OTAAdminChannelFactory?) {
        register(.nodes) { [self] in
            AnyView(NodeDirectoryView(
                viewModel: NodeDirectoryViewModel(store: store),
                onApply: { _ in self.onNavigate?(.fleet) },
                onOpenAnalytics: { _ in self.onNavigate?(.analytics) },
                onCommand: { command in
                    guard let otaFactory else { return }
                    Task { try? await otaFactory.send(command) }
                }
            ))
        }
    }

    /// Fleet + Provision sections. Split out of `registerLiveSections` so each
    /// function stays within the lint body-length cap. Both apply through the real
    /// OTA channel when `otaFactory` is present, else the store-backed default.
    @MainActor
    private func registerProvisioningSections(store: MeshStore, otaFactory: OTAAdminChannelFactory?) {
        register(.fleet) {
            AnyView(FleetConfigConsole(viewModel: FleetConfigViewModel(
                store: store,
                channelFor: otaFactory?.fleetChannelFor()
            )))
        }
        register(.provision) {
            AnyView(ProvisioningWorkflowView(
                viewModel: ProvisioningWorkflowFactory.make(
                    store: store,
                    draft: .init(),
                    channelFor: otaFactory?.provisionChannelFor()
                )
            ))
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
    /// The shared store, retained so `.task` can read the persisted default-snooze
    /// duration before the console's first Snooze (Finding 12).
    private let store: MeshStore

    init(store: MeshStore, clock: any Domain.Clock) {
        self.store = store
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
            // Honour the operator's persisted default-snooze duration (Finding 12),
            // loaded in `.task` below — no more hardcoded 3600s.
            onSnooze: { item in Task { try? await alerts.snooze(item) } },
            onResolve: { item in Task { try? await alerts.resolve(item) } }
        )
        .task {
            alerts.defaultSnoozeSeconds = await (try? AlertDefaultSnoozeStore.load(from: store))
                ?? AlertDefaultSnoozeStore.fallbackSeconds
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
