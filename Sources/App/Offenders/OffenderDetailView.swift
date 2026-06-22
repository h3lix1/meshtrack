// OffenderDetailView — the per-node why/how/when panel opened by tapping an offender
// row. Bespoke dark-theme cards (no stock List/ScrollView/Chart) so it snapshots
// deterministically; the card stack lives inside a `ScrollView` around an intrinsic-
// height `pageContent` subview (mirrors `CollisionMatrixView`). Pure presentation:
// hand it an `OffenderDetail` (derived in `TrafficProjection.offenderDetail`).
//
//   WHY  — receptions, distinct emitted, spread, packets/min, dominant port.
//   HOW  — per-port breakdown (counts + share), gateways heard it, hop range.
//   WHEN — first/last heard + a per-minute activity sparkline.

import Domain
import Foundation
import SwiftUI

/// The per-node detail panel. `onBack` returns to the ranking list.
public struct OffenderDetailView: View {
    public let detail: OffenderDetail
    public let rank: Int?
    private let onBack: () -> Void

    public init(detail: OffenderDetail, rank: Int? = nil, onBack: @escaping () -> Void) {
        self.detail = detail
        self.rank = rank
        self.onBack = onBack
    }

    public var body: some View {
        ScrollView(.vertical) {
            pageContent
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OffenderTheme.background)
        .foregroundStyle(.white)
    }

    /// The scrollable card stack, at intrinsic height (no trailing `Spacer`) so headless
    /// snapshots render the whole panel rather than a collapsed strip.
    var pageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            whyCard
            howCard
            whenCard
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Back to ranking").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(OffenderTheme.rankColor(rank))
            }
            .buttonStyle(.plain)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let rank {
                    Text("#\(rank)").font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(OffenderTheme.rankColor(rank))
                }
                Text(detail.hexID).font(.system(size: 22, weight: .bold, design: .monospaced))
            }
            Text("Why this node offends, how its traffic breaks down, and when it is active.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: WHY

    private var whyCard: some View {
        OffenderCard(title: "WHY — TRAFFIC BURDEN") {
            HStack(alignment: .top, spacing: 18) {
                stat("\(detail.receptions)", "FLOOD RECEPTIONS")
                stat("\(detail.emitted)", "DISTINCT EMITTED")
                stat("\(detail.spread)", "GATEWAY SPREAD")
                stat(perMinuteLabel, "PKT / MIN")
            }
            HStack(spacing: 4) {
                Text("Dominant port:").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(detail.dominantPort?.name ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            if let summary = detail.dominantPort?.summary {
                Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: HOW

    private var howCard: some View {
        OffenderCard(title: "HOW — PER-PORT BREAKDOWN") {
            portHeadings
            ForEach(detail.ports) { port in
                OffenderPortRowView(row: port)
            }
            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 2)
            hopAndGateways
        }
    }

    private var portHeadings: some View {
        HStack(spacing: 8) {
            Text("PORT").frame(width: 190, alignment: .leading)
            Text("EMIT").frame(width: 52, alignment: .trailing)
            Text("RECV").frame(width: 56, alignment: .trailing)
            Text("SHARE").frame(width: 56, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
    }

    private var hopAndGateways: some View {
        VStack(alignment: .leading, spacing: 6) {
            labelled("HOP RANGE", detail.hopRangeLabel)
            labelled("GATEWAYS HEARD IT", gatewayLabel)
        }
    }

    // MARK: WHEN

    private var whenCard: some View {
        OffenderCard(title: "WHEN — ACTIVITY OVER TIME") {
            HStack(alignment: .top, spacing: 18) {
                stat(Self.timestamp(detail.firstSeen), "FIRST HEARD")
                stat(Self.timestamp(detail.lastSeen), "LAST HEARD")
                stat(windowLabel, "WINDOW")
            }
            if detail.activity.isEmpty {
                Text("No activity recorded yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Receptions per minute since first heard")
                    .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                ActivitySparkline(
                    buckets: detail.activity,
                    peak: detail.peakActivity,
                    color: OffenderTheme.rankColor(rank)
                )
            }
        }
    }

    // MARK: Small building blocks

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced))
            Spacer(minLength: 0)
        }
    }

    private var perMinuteLabel: String {
        String(format: "%.1f", detail.packetsPerMinute)
    }

    private var windowLabel: String {
        let seconds = detail.windowSeconds
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = seconds / 60
        return minutes < 60 ? String(format: "%.1fm", minutes) : String(format: "%.1fh", minutes / 60)
    }

    private var gatewayLabel: String {
        guard !detail.gateways.isEmpty else { return "—" }
        return detail.gateways.map { String(format: "0x%X", $0) }.joined(separator: " ")
    }

    /// Format an `Instant` as a short wall-clock time. The detail view lives in the App
    /// layer (Foundation allowed), so it may bridge to `Date` for display only.
    static func timestamp(_ instant: Instant?) -> String {
        guard let instant else { return "—" }
        let date = Date(timeIntervalSince1970: Double(instant.nanosecondsSinceEpoch) / 1_000_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// A titled dark card matching the offenders palette.
struct OffenderCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(OffenderTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One per-port row in the HOW breakdown, with an inline share bar.
struct OffenderPortRowView: View {
    let row: OffenderPortRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.descriptor.name).font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).frame(width: 190, alignment: .leading)
                Text("\(row.emitted)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, alignment: .trailing)
                Text("\(row.receptions)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(width: 56, alignment: .trailing)
                Text(row.sharePercentLabel).font(.system(size: 12, weight: .medium))
                    .frame(width: 56, alignment: .trailing)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.05))
                    Capsule().fill(Color(red: 0.45, green: 0.72, blue: 0.95).opacity(0.5))
                        .frame(width: max(2, geo.size.width * row.share))
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 3)
    }
}

/// A bespoke per-minute activity sparkline (bars), drawn with shapes so it hit-tests
/// and renders faithfully headless (no stock Chart).
struct ActivitySparkline: View {
    let buckets: [ActivityBucketRow]
    let peak: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(buckets.count, 1)
            let gap: CGFloat = 2
            let barWidth = max(1, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(buckets) { bucket in
                    Capsule()
                        .fill(bucket.receptions == 0 ? Color.white.opacity(0.06) : color.opacity(0.75))
                        .frame(width: barWidth, height: barHeight(bucket.receptions, in: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 56)
    }

    /// Bar height proportional to the bucket's receptions over the peak; a floor keeps
    /// non-zero minutes visible, and zero minutes draw a thin baseline tick.
    private func barHeight(_ receptions: Int, in available: CGFloat) -> CGFloat {
        guard peak > 0 else { return 1 }
        guard receptions > 0 else { return 1 }
        return max(3, available * CGFloat(receptions) / CGFloat(peak))
    }
}
