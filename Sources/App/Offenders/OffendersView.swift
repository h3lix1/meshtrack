// OffendersView — the Largest-offenders screen (item 12). Ranks nodes by mesh-
// traffic burden with enough detail to act: node id, packets emitted, flood
// receptions, spread across gateways, packets-per-minute (chattiness), and the
// node's dominant port. Bespoke dark-theme view (no stock List/ScrollView) so it
// snapshots deterministically. The view model hydrates an all-time ranking from the
// durable `node_traffic_stat` table on appear.

import Domain
import SwiftUI

/// The section wrapper the composition root registers: owns the live view model,
/// loads the persisted all-time ranking on appear, and renders the screen.
public struct OffendersSection: View {
    @State private var viewModel: OffendersViewModel

    public init(viewModel: OffendersViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        OffendersView(rows: viewModel.rows, totalReceptions: viewModel.totalReceptions)
            .task { await viewModel.loadPersisted() }
    }
}

/// The pure presentation view: hand it ranked rows, it draws.
public struct OffendersView: View {
    public let rows: [OffenderRow]
    public let totalReceptions: Int

    public init(rows: [OffenderRow], totalReceptions: Int) {
        self.rows = rows
        self.totalReceptions = totalReceptions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            columnHeadings
            if rows.isEmpty {
                emptyState
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    OffenderRowView(rank: index + 1, row: row, peak: rows.first?.receptions ?? 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
        .foregroundStyle(.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Largest Offenders").font(.system(size: 22, weight: .bold))
            Text("Nodes ranked by mesh-traffic burden — flood receptions, packets "
                + "originated, spread across gateways, and chattiness per minute.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                metric("RECEPTIONS", "\(totalReceptions)")
                metric("RANKED NODES", "\(rows.count)")
            }
            .padding(.top, 4)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 8) {
            Text("#").frame(width: 28, alignment: .leading)
            Text("NODE").frame(width: 150, alignment: .leading)
            Text("RECV").frame(width: 56, alignment: .trailing)
            Text("EMIT").frame(width: 52, alignment: .trailing)
            Text("SPREAD").frame(width: 60, alignment: .trailing)
            Text("PKT/MIN").frame(width: 64, alignment: .trailing)
            Text("DOMINANT PORT").frame(width: 150, alignment: .leading).padding(.leading, 10)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        Text("No traffic yet — offenders appear as nodes transmit.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.vertical, 24)
    }
}

/// One ranked offender row.
struct OffenderRowView: View {
    let rank: Int
    let row: OffenderRow
    let peak: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(rank)").font(.system(size: 12, weight: .bold)).foregroundStyle(rankColor)
                    .frame(width: 28, alignment: .leading)
                Text(row.hexID).font(.system(size: 13, design: .monospaced))
                    .frame(width: 150, alignment: .leading)
                Text("\(row.receptions)").frame(width: 56, alignment: .trailing)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("\(row.emitted)").frame(width: 52, alignment: .trailing)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                Text("\(row.spread)").frame(width: 60, alignment: .trailing)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                Text(perMinuteLabel).frame(width: 64, alignment: .trailing)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(rankColor)
                Text(row.dominantPort?.name ?? "—")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(width: 150, alignment: .leading).padding(.leading, 10)
                Spacer(minLength: 0)
            }
            burdenBar
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.05)).frame(height: 1)
        }
    }

    private var perMinuteLabel: String {
        String(format: "%.1f", row.packetsPerMinute)
    }

    private var burdenBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.05))
                Capsule().fill(rankColor.opacity(0.5))
                    .frame(width: max(3, geo.size.width * Double(row.receptions) / Double(max(peak, 1))))
            }
        }
        .frame(height: 3)
    }

    /// Top offenders glow red→amber; the long tail cools to blue.
    private var rankColor: Color {
        switch rank {
        case 1: Color(red: 0.95, green: 0.42, blue: 0.38)
        case 2, 3: Color(red: 0.97, green: 0.7, blue: 0.34)
        default: Color(red: 0.45, green: 0.72, blue: 0.95)
        }
    }
}
