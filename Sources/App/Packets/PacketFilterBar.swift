// FilterBar — the bespoke filter affordances for the packet inspector (G6): a text
// field plus port / source-node menus driven off the live window. Hand-rolled
// chips (no stock segmented control) so it renders under the snapshot gate.

import Domain
import SwiftUI

struct FilterBar: View {
    @Bindable var viewModel: PacketInspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter…", text: $viewModel.filter.text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            if !viewModel.knownPorts.isEmpty {
                portChips
            }

            if viewModel.filter.isActive {
                Button {
                    viewModel.filter = PacketFilter()
                } label: {
                    Text("Clear filters")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PacketInspectorTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var portChips: some View {
        // wrap chips manually (no LazyVGrid stock chrome) for snapshot fidelity.
        let ports = viewModel.knownPorts
        return HStack(spacing: 4) {
            chip(label: "ALL", active: viewModel.filter.port == nil) {
                viewModel.filter.port = nil
            }
            ForEach(ports.prefix(3), id: \.portNumRawValue) { port in
                chip(
                    label: shortLabel(port),
                    active: viewModel.filter.port?.portNumRawValue == port.portNumRawValue
                ) {
                    viewModel.filter.port = port
                }
            }
        }
    }

    private func chip(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(
                    active ? PacketInspectorTheme.accent.opacity(0.8) : Color.white.opacity(0.06),
                    in: Capsule()
                )
                .foregroundStyle(active ? .black : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func shortLabel(_ port: MeshPort) -> String {
        switch port {
        case .textMessage: "TEXT"
        case .position: "POS"
        case .nodeInfo: "INFO"
        case .routing: "ROUTE"
        case .admin: "ADMIN"
        case .waypoint: "WPT"
        case .telemetry: "TELEM"
        case .mapReport: "MAP"
        case let .other(raw): "\(raw)"
        }
    }
}
