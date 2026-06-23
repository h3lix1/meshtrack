// NodesView — a grid of node cards (name, hex id, battery gauge, hops). Renders
// over the live node list; here driven by sample data for snapshots.

import Domain
import SwiftUI

public struct NodesView: View {
    public let nodes: [NetworkNode]
    @State private var selected: NetworkNode?
    public init(nodes: [NetworkNode]) {
        self.nodes = nodes
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
                ForEach(nodes) { node in
                    NodeCard(node: node)
                        .onTapGesture { selected = node }
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
        .sheet(item: $selected) { NodeDetailView(node: $0) }
    }
}

struct NodeCard: View {
    let node: NetworkNode

    private var hexID: String {
        NodeID.hex(UInt32(truncatingIfNeeded: node.id))
    }

    private var batteryColor: Color {
        guard let battery = node.batteryPercent else { return .gray }
        return battery < 20 ? .red : (battery < 50 ? .yellow : .green)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(node.isGateway ? Color.cyan : .blue).frame(width: 9, height: 9)
                Text(node.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if node.isGateway {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.cyan)
                }
            }
            Text(hexID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)

            if let battery = node.batteryPercent {
                HStack(spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(batteryColor).frame(width: geo.size.width * battery / 100)
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int(battery))%").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(batteryColor)
                }
            }

            Label(
                "\(node.hopsFromGateway) hop\(node.hopsFromGateway == 1 ? "" : "s") from gateway",
                systemImage: "arrow.triangle.branch"
            )
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06)))
    }
}
