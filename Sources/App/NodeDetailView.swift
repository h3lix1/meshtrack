// NodeDetailView — click a node to inspect + configure it (SPEC §2). Shows live
// stats, then a config form gated behind an ARM toggle: nothing can be written
// until the operator explicitly arms, and the apply goes through the verified
// rolling apply (AdminApplier / FleetApplier). Bespoke chip/switch controls so the
// dark theme is consistent and the headless snapshot renders faithfully.

import Domain
import SwiftUI

public struct NodeDetailView: View {
    public let node: NetworkNode
    public var onApply: (NodeConfigEdit) -> Void

    @State private var name: String
    @State private var region: String
    @State private var role: String
    @State private var armed: Bool

    private let regions = ["US", "EU_868", "EU_433", "ANZ", "CN", "JP", "IN", "KR"]
    private let roles = ["CLIENT", "CLIENT_MUTE", "ROUTER", "ROUTER_CLIENT", "REPEATER", "TRACKER"]

    public init(
        node: NetworkNode,
        region: String = "US",
        role: String = "CLIENT",
        armedForPreview: Bool = false,
        onApply: @escaping (NodeConfigEdit) -> Void = { _ in }
    ) {
        self.node = node
        self.onApply = onApply
        _name = State(initialValue: node.name)
        _region = State(initialValue: region)
        _role = State(initialValue: role)
        _armed = State(initialValue: armedForPreview)
    }

    private var hexID: String {
        NodeID.hex(UInt32(truncatingIfNeeded: node.id))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            VStack(alignment: .leading, spacing: 20) {
                statsGrid
                configForm
                armingSection
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 420, height: 600)
        .background(Color(red: 0.05, green: 0.06, blue: 0.14))
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(node.isGateway ? Color.cyan : .blue).frame(width: 11, height: 11)
                .shadow(color: node.isGateway ? .cyan : .blue, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.system(size: 17, weight: .bold))
                Text(hexID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if node.isGateway {
                Label("Gateway", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.cyan.opacity(0.18), in: Capsule()).foregroundStyle(.cyan)
            }
        }
        .padding(18)
    }

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(
                label: "BATTERY",
                value: node.batteryPercent.map { "\(Int($0))%" } ?? "—",
                tint: (node.batteryPercent ?? 100) < 20 ? .red : .green
            )
            StatTile(label: "HOPS FROM GW", value: "\(node.hopsFromGateway)", tint: .cyan)
            StatTile(label: "LATITUDE", value: String(format: "%.4f", node.position.latitude), tint: .white)
            StatTile(label: "LONGITUDE", value: String(format: "%.4f", node.position.longitude), tint: .white)
        }
    }

    private var configForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONFIGURATION").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            labeled("Name") {
                HStack {
                    Text(name).font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Image(systemName: "pencil").font(.caption).foregroundStyle(armed ? .cyan : .secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(armed ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            labeled("Region") { ChipPicker(options: regions, selection: $region, enabled: armed) }
            labeled("Role") { ChipPicker(options: roles, selection: $role, enabled: armed) }
        }
    }

    private func labeled(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            control()
        }
    }

    private var armingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { armed.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: armed ? "lock.open.fill" : "lock.fill")
                    Text(armed ? "ARMED — changes enabled" : "Safe — tap to arm")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Capsule().fill(armed ? Color.orange : .gray.opacity(0.4))
                        .frame(width: 42, height: 24)
                        .overlay(Circle().fill(.white).frame(width: 18, height: 18).offset(x: armed ? 9 : -9))
                }
                .foregroundStyle(armed ? .orange : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                onApply(NodeConfigEdit(nodeNum: node.id, name: name, region: region, role: role))
            } label: {
                Text("Apply via verified rolling update")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        armed ? Color.cyan : .gray.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .foregroundStyle(armed ? .black : .white.opacity(0.4))
            }
            .buttonStyle(.plain).disabled(!armed)

            Text("Applies through AdminApplier: render → diff → write → read-back verify.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(armed ? .orange.opacity(0.5) : .clear, lineWidth: 1)
        )
    }
}

public struct NodeConfigEdit: Sendable, Equatable {
    public let nodeNum: Int64
    public let name: String
    public let region: String
    public let role: String
}

private struct ChipPicker: View {
    let options: [String]
    @Binding var selection: String
    let enabled: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Text(option)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(isSelected ? Color.cyan.opacity(0.22) : .white.opacity(0.05), in: Capsule())
                    .overlay(Capsule().stroke(isSelected ? Color.cyan : .clear, lineWidth: 1))
                    .foregroundStyle(isSelected ? .cyan : .white.opacity(enabled ? 0.7 : 0.35))
                    .onTapGesture { if enabled { selection = option } }
            }
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
