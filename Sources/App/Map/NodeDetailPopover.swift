// NodeDetailPopover — the popover shown when a map marker is tapped (Task 5/6). It
// shows the node's name, coordinates, latest battery/telemetry and role/hw/last-heard
// from a store-backed NodeDetailViewModel, and a "More Details" button that pushes the
// fuller per-node analytics view (NodeAnalyticsView over NodeAnalyticsViewModel) —
// reused verbatim from App/Analytics, not edited (Task 6).
//
// Live-app surface; the headless snapshot path uses the Canvas map (DashboardView).

#if canImport(MapKit) && os(macOS)
    import Domain
    import Persistence
    import SwiftUI

    struct NodeDetailPopover: View {
        let node: NetworkNode
        let store: MeshStore

        @State private var viewModel: NodeDetailViewModel
        @State private var showAnalytics = false

        init(node: NetworkNode, store: MeshStore) {
            self.node = node
            self.store = store
            _viewModel = State(initialValue: NodeDetailViewModel(store: store, nodeNum: node.id))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().overlay(Color.white.opacity(0.12))
                coordinatesRow
                identityRows
                if !viewModel.latestTelemetry.isEmpty {
                    Divider().overlay(Color.white.opacity(0.12))
                    telemetryGrid
                }
                Divider().overlay(Color.white.opacity(0.12))
                moreDetailsButton
            }
            .padding(16)
            .frame(width: 280, alignment: .leading)
            .foregroundStyle(.white)
            .background(Color(red: 0.05, green: 0.06, blue: 0.12))
            .task { try? await viewModel.load() }
            .sheet(isPresented: $showAnalytics) {
                analyticsSheet
            }
        }

        // MARK: Header

        private var header: some View {
            HStack(spacing: 8) {
                Circle()
                    .fill(node.isGateway ? Color(red: 0.3, green: 0.95, blue: 1.0) : .blue)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.name ?? node.name).font(.headline)
                    if let preset = node.preset {
                        Text(preset.displayName).font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                if let battery = viewModel.batteryPercent ?? node.batteryPercent {
                    Text("\(Int(battery))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(batteryColor(battery))
                }
            }
        }

        // MARK: Rows

        private var coordinatesRow: some View {
            let coordinate = viewModel.coordinate ?? node.position
            return detailRow(
                "Coordinates",
                String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
            )
        }

        @ViewBuilder private var identityRows: some View {
            if let role = viewModel.role, !role.isEmpty { detailRow("Role", role) }
            if let hardware = viewModel.hardwareModel, !hardware.isEmpty {
                detailRow("Hardware", hardware)
            }
            detailRow("Gateway", node.isGateway ? "Yes" : "No")
            if let lastHeard = viewModel.lastHeard {
                detailRow("Last heard", Self.relativeLastHeard(lastHeard))
            }
        }

        private var telemetryGrid: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Telemetry").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                ForEach(viewModel.latestTelemetry) { reading in
                    detailRow(reading.label, reading.formatted)
                }
            }
        }

        private func detailRow(_ label: String, _ value: String) -> some View {
            HStack {
                Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(value).font(.caption.monospacedDigit())
            }
        }

        // MARK: More details

        private var moreDetailsButton: some View {
            Button {
                showAnalytics = true
            } label: {
                HStack {
                    Text("More Details")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 1.0))
        }

        private var analyticsSheet: some View {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showAnalytics = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                NodeAnalyticsView(viewModel: NodeAnalyticsViewModel(store: store, nodeNum: node.id))
            }
            .frame(minWidth: 640, minHeight: 520)
        }

        // MARK: Helpers

        private func batteryColor(_ percent: Double) -> Color {
            percent < 20 ? .red : (percent < 50 ? .yellow : .green)
        }

        /// A coarse "x ago" string relative to now. Self-contained — the popover only
        /// needs a rough freshness hint, not a full relative-time engine.
        static func relativeLastHeard(_ instant: Instant, now: Date = Date()) -> String {
            let seconds = now.timeIntervalSince1970
                - Double(instant.nanosecondsSinceEpoch) / 1_000_000_000
            guard seconds >= 0 else { return "just now" }
            switch seconds {
            case ..<60: return "just now"
            case ..<3600: return "\(Int(seconds / 60))m ago"
            case ..<86400: return "\(Int(seconds / 3600))h ago"
            default: return "\(Int(seconds / 86400))d ago"
            }
        }
    }
#endif
