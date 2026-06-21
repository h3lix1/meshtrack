// FleetConfigView — visualises a safe rolling fleet update: each node verified
// before the next (SPEC §2.7). Backed by FleetApplier; here driven by sample rows.

import SwiftUI

public struct FleetRolloutRow: Identifiable, Sendable {
    public enum Status: Sendable, Equatable { case verified, applying, pending, failed }

    public let id = UUID()
    public let nodeName: String
    public let status: Status

    public init(nodeName: String, status: Status) {
        self.nodeName = nodeName
        self.status = status
    }
}

public struct FleetConfigView: View {
    public let rows: [FleetRolloutRow]
    public init(rows: [FleetRolloutRow]) {
        self.rows = rows
    }

    private var verified: Int {
        rows.count { $0.status == .verified }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fleet Configuration").font(.title.bold()).foregroundStyle(.white)
                Text("Each node is verified before the next, so a bad change can't destabilise the fleet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(.green)
                            .frame(width: geo.size.width * Double(verified) / Double(max(rows.count, 1)))
                    }
                }
                .frame(height: 8)
                Text("\(verified)/\(rows.count) verified")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
            }
            VStack(spacing: 8) {
                ForEach(rows) { FleetRow(row: $0) }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }
}

struct FleetRow: View {
    let row: FleetRolloutRow

    private var color: Color {
        switch row.status {
        case .verified: .green
        case .applying: .cyan
        case .pending: .gray
        case .failed: .red
        }
    }

    private var icon: String {
        switch row.status {
        case .verified: "checkmark.circle.fill"
        case .applying: "arrow.triangle.2.circlepath"
        case .pending: "circle"
        case .failed: "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            Text(row.nodeName).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            Spacer()
            Text(String(describing: row.status).uppercased())
                .font(.system(size: 9, weight: .bold)).foregroundStyle(color)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
