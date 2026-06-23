// AnalyticsCharts — bespoke Canvas/Path renderers for the node-analytics tabs
// (Phase 7 G4). Stock controls + Swift Charts render badly under the headless
// ImageRenderer snapshot gate (cf. project memory), so the deep-dive's histograms,
// radial topology graph, heatmap, and breakdown are drawn directly into a Canvas.
// Every renderer is a pure function of its (already-aggregated) input → fully
// deterministic, snapshot-friendly, no async, no system controls.

import Domain
import SwiftUI

// MARK: - Histogram (signal distribution, hop counts)

/// A vertical-bar histogram drawn in a Canvas. `bars` is (label, value); the tallest
/// bar fills the height. Used for SNR/RSSI distribution and the hop-count histogram.
struct HistogramChart: View {
    let bars: [(label: String, value: Double)]
    var barColor: Color = AnalyticsTheme.accent

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else {
                drawEmpty(context, size: size)
                return
            }
            let maxValue = bars.map(\.value).max() ?? 0
            let axisInset: CGFloat = 24
            let plot = CGRect(
                x: axisInset, y: 8,
                width: size.width - axisInset, height: size.height - axisInset - 8
            )
            let slot = plot.width / CGFloat(bars.count)
            let gap = slot * 0.18
            for (index, bar) in bars.enumerated() {
                let fraction = maxValue > 0 ? CGFloat(bar.value / maxValue) : 0
                let barHeight = plot.height * fraction
                let rect = CGRect(
                    x: plot.minX + CGFloat(index) * slot + gap / 2,
                    y: plot.maxY - barHeight,
                    width: slot - gap,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 3),
                    with: .color(barColor.opacity(bar.value > 0 ? 0.9 : 0.18))
                )
                // x label every nth bar to avoid clutter.
                if bars.count <= 14 || index % 2 == 0 {
                    let text = context.resolve(
                        Text(bar.label).font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                    )
                    context.draw(text, at: CGPoint(x: rect.midX, y: plot.maxY + 10))
                }
            }
            // baseline
            var axis = Path()
            axis.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            axis.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            context.stroke(axis, with: .color(.white.opacity(0.15)), lineWidth: 1)
        }
    }

    private func drawEmpty(_ context: GraphicsContext, size: CGSize) {
        let text = context.resolve(
            Text("No data").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
        )
        context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}

// MARK: - Radial topology graph

/// A radial peer/topology graph: the focus node at centre, each gateway/relay that
/// heard it on a ring, edge thickness ∝ reception count, hue ∝ average SNR. Drawn
/// in a Canvas with a fixed angular layout, so it's deterministic headless.
struct PeerTopologyGraph: View {
    let nodeName: String
    let peers: [PeerSummary]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            guard !peers.isEmpty else {
                let text = context.resolve(
                    Text("No peers yet").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                )
                context.draw(text, at: center)
                return
            }
            let radius = min(size.width, size.height) / 2 - 56
            let maxCount = peers.map(\.receptionCount).max() ?? 1
            // Edges first (under the nodes).
            for (index, peer) in peers.enumerated() {
                let point = peerPoint(index: index, count: peers.count, center: center, radius: radius)
                var edge = Path()
                edge.move(to: center)
                edge.addLine(to: point)
                let weight = CGFloat(peer.receptionCount) / CGFloat(maxCount)
                context.stroke(
                    edge,
                    with: .color(snrColor(peer.averageSNR).opacity(0.45 + 0.4 * weight)),
                    lineWidth: 1 + 5 * weight
                )
            }
            // Peer nodes.
            for (index, peer) in peers.enumerated() {
                let point = peerPoint(index: index, count: peers.count, center: center, radius: radius)
                drawNode(
                    context,
                    at: point,
                    radius: 9,
                    fill: snrColor(peer.averageSNR),
                    label: peer.gatewayID
                )
                let count = context.resolve(
                    Text("\(peer.receptionCount)").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                )
                context.draw(count, at: point)
            }
            // Focus node on top.
            drawNode(context, at: center, radius: 13, fill: AnalyticsTheme.accent, label: nodeName)
        }
    }

    private func peerPoint(index: Int, count: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        // Start at the top, distribute clockwise — deterministic.
        let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(count)
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func drawNode(
        _ context: GraphicsContext,
        at point: CGPoint,
        radius: CGFloat,
        fill: Color,
        label: String
    ) {
        let circle = Path(ellipseIn: CGRect(
            x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2
        ))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.fill(circle, with: .color(fill.opacity(0.5)))
        }
        context.fill(circle, with: .color(fill))
        let text = context.resolve(
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        )
        context.draw(text, at: CGPoint(x: point.x, y: point.y + radius + 9))
    }

    /// Green (strong) → amber → red (weak) by average SNR; grey when unknown.
    private func snrColor(_ snr: Double?) -> Color {
        guard let snr else { return Color(white: 0.55) }
        switch snr {
        case 0...: return Color(red: 0.35, green: 0.9, blue: 0.5)
        case -8 ..< 0: return Color(red: 0.55, green: 0.85, blue: 0.45)
        case -15 ..< -8: return Color(red: 0.95, green: 0.8, blue: 0.35)
        default: return Color(red: 0.95, green: 0.45, blue: 0.4)
        }
    }
}

// MARK: - Hourly activity heatmap

/// A 24-cell hour-of-day heatmap (a single row of cells, 0…23), cell brightness ∝
/// reception count. Bespoke Canvas grid → deterministic headless.
struct HourlyHeatmap: View {
    let buckets: [HourBucket]

    var body: some View {
        Canvas { context, size in
            guard !buckets.isEmpty else { return }
            let maxCount = buckets.map(\.count).max() ?? 0
            let labelH: CGFloat = 16
            let cols = 24
            let gap: CGFloat = 3
            let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = max(0, size.height - labelH)
            for bucket in buckets {
                let x = CGFloat(bucket.hour) * (cellW + gap)
                let rect = CGRect(x: x, y: 0, width: cellW, height: cellH)
                let intensity = maxCount > 0 ? Double(bucket.count) / Double(maxCount) : 0
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 3),
                    with: .color(AnalyticsTheme.accent.opacity(0.12 + 0.85 * intensity))
                )
                if bucket.hour % 3 == 0 {
                    let text = context.resolve(
                        Text("\(bucket.hour)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55))
                    )
                    context.draw(text, at: CGPoint(x: rect.midX, y: cellH + 8))
                }
            }
        }
    }
}

// MARK: - Packet-type breakdown (horizontal bars)

/// A horizontal-bar breakdown of packet counts per `MeshPort`. Bespoke Canvas →
/// deterministic headless (no stock List/ProgressView).
struct PacketTypeBreakdown: View {
    let counts: [PacketTypeCount]

    var body: some View {
        Canvas { context, size in
            guard !counts.isEmpty else {
                let text = context.resolve(
                    Text("No packets yet").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                )
                context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let maxCount = counts.map(\.count).max() ?? 1
            let labelW: CGFloat = 96
            let valueW: CGFloat = 36
            let rowH = min(34, (size.height) / CGFloat(counts.count))
            let barMaxW = size.width - labelW - valueW
            for (index, item) in counts.enumerated() {
                let y = CGFloat(index) * rowH
                let mid = y + rowH / 2
                let label = context.resolve(
                    Text(item.label).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                )
                context.draw(label, at: CGPoint(x: labelW - 8, y: mid), anchor: .trailing)
                let fraction = CGFloat(item.count) / CGFloat(maxCount)
                let barRect = CGRect(
                    x: labelW, y: y + rowH * 0.2,
                    width: max(2, barMaxW * fraction), height: rowH * 0.6
                )
                context.fill(
                    Path(roundedRect: barRect, cornerRadius: 3),
                    with: .color(PacketColor
                        .color(for: UInt32(truncatingIfNeeded: item.port.portNumRawValue + 1)))
                )
                let value = context.resolve(
                    Text("\(item.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                )
                context.draw(value, at: CGPoint(x: size.width - 4, y: mid), anchor: .trailing)
            }
        }
    }
}
