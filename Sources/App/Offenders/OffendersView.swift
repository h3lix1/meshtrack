// OffendersView — the Largest-offenders screen (items 12 / 3+4). Ranks nodes by
// mesh-traffic burden with enough detail to act: node id, packets emitted, flood
// receptions, spread across gateways, packets-per-minute (chattiness), and the
// node's dominant port. Tapping a row opens a per-node why/how/when detail panel
// (`OffenderDetailView`). Bespoke dark-theme views (no stock List/ScrollView/Toggle)
// so they snapshot deterministically; the ranking lives inside a `ScrollView` around
// a bespoke `rankingContent` subview (intrinsic height) so a long list is reachable
// yet headless `ImageRenderer` snapshots render the full stack. The view model
// hydrates an all-time ranking from the durable `node_traffic_stat` table on appear.

import Domain
import SwiftUI

/// The section wrapper the composition root registers: owns the live view model,
/// loads the persisted all-time ranking on appear, and renders either the ranking or
/// (when a row is selected) the per-node detail panel.
public struct OffendersSection: View {
    @State private var viewModel: OffendersViewModel

    public init(viewModel: OffendersViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Group {
            if let detail = viewModel.selectedDetail {
                OffenderDetailView(detail: detail, rank: rank(of: detail.nodeNum)) {
                    viewModel.clearSelection()
                }
            } else {
                OffendersView(
                    rows: viewModel.rows,
                    totalReceptions: viewModel.totalReceptions,
                    onSelect: { viewModel.select(nodeNum: $0) }
                )
            }
        }
        .task { await viewModel.loadPersisted() }
    }

    /// 1-based rank of a node within the current ranking, for the detail header.
    private func rank(of nodeNum: UInt32) -> Int? {
        viewModel.rows.firstIndex { $0.nodeNum == nodeNum }.map { $0 + 1 }
    }
}

/// The pure presentation view: hand it ranked rows, it draws. The ranking scrolls;
/// `onSelect` (when set) makes each row a tap target opening the detail panel.
public struct OffendersView: View {
    public let rows: [OffenderRow]
    public let totalReceptions: Int
    private let onSelect: ((UInt32) -> Void)?

    public init(rows: [OffenderRow], totalReceptions: Int, onSelect: ((UInt32) -> Void)? = nil) {
        self.rows = rows
        self.totalReceptions = totalReceptions
        self.onSelect = onSelect
    }

    public var body: some View {
        // The ranking can be long, so it lives inside a vertical `ScrollView`. The
        // scrollable rows are factored into `rankingContent` (a bespoke subview that
        // lays out at intrinsic height, no trailing unbounded `Spacer`) so headless
        // `ImageRenderer` snapshots — which have no scroll viewport — render the full
        // list instead of a collapsed strip. Mirrors `CollisionMatrixView.pageContent`.
        ScrollView(.vertical) {
            rankingContent
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OffenderTheme.background)
        .foregroundStyle(.white)
    }

    /// The scrollable card stack: header, column headings, and the ranked rows.
    var rankingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            columnHeadings
            if rows.isEmpty {
                emptyState
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    OffenderRowView(
                        rank: index + 1,
                        row: row,
                        peak: rows.first?.receptions ?? 1,
                        onSelect: onSelect
                    )
                }
            }
        }
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
            if onSelect != nil, !rows.isEmpty {
                Text("Tap a node to inspect why / how / when it offends.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
            }
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

/// One ranked offender row. A tap target when `onSelect` is wired (opens detail).
struct OffenderRowView: View {
    let rank: Int
    let row: OffenderRow
    let peak: Int
    var onSelect: ((UInt32) -> Void)?

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
                if onSelect != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            burdenBar
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.05)).frame(height: 1)
        }
        .onTapGesture { onSelect?(row.nodeNum) }
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
        OffenderTheme.rankColor(rank)
    }
}

/// Shared palette for the offenders screen + detail panel, so both read identically.
enum OffenderTheme {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.10)
    static let card = Color(red: 0.08, green: 0.10, blue: 0.18)

    /// Top offenders glow red→amber; the long tail cools to blue. `nil`/0 ranks cool.
    static func rankColor(_ rank: Int?) -> Color {
        switch rank ?? 0 {
        case 1: Color(red: 0.95, green: 0.42, blue: 0.38)
        case 2, 3: Color(red: 0.97, green: 0.7, blue: 0.34)
        default: Color(red: 0.45, green: 0.72, blue: 0.95)
        }
    }
}
