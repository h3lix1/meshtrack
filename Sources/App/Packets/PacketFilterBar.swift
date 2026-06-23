// FilterBar — the bespoke filter affordances for the packet inspector (G6): a text
// field plus port / source-node menus driven off the live window. Hand-rolled
// chips (no stock segmented control) so it renders under the snapshot gate.

import Domain
import SwiftUI

struct FilterBar: View {
    @Bindable var viewModel: PacketInspectorViewModel

    /// The selectable window sizes shown in the bespoke segmented control (item 7).
    private let windowOptions = PacketWindowPreference.options

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

            windowSizeControl

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

    /// Bespoke segmented window-size picker (no stock Picker) — taps grow/shrink the
    /// VM's live window cap, evicting on shrink while honouring the selection pin. The
    /// active highlight reads the VM's `windowSize` (the source of truth), and each tap
    /// pushes into the VM and persists to `UserDefaults`. We use no `@AppStorage` and
    /// no view-lifecycle VM mutation — both crash the headless ImageRenderer render
    /// pass; the one-time restore from persistence happens in the section's `onAppear`
    /// (deferred off the render pass).
    private var windowSizeControl: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WINDOW")
                .font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(windowOptions, id: \.self) { size in
                    chip(label: "\(size)", active: viewModel.windowSize == size) {
                        viewModel.windowSize = size // live resize (tap action, render-safe)
                        PacketWindowPreference.persist(size) // remember the choice
                    }
                }
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
